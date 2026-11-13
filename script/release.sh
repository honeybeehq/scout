#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project_yml="$root/mac/project.yml"
entitlements="$root/mac/Scout/Scout.entitlements"
identity="${SCOUT_SIGN_IDENTITY:-Developer ID Application: Ur Solutions AS (4QK8JBAU4V)}"
team_id="${SCOUT_TEAM_ID:-4QK8JBAU4V}"
notary_profile="${SCOUT_NOTARY_PROFILE:-apiary-notary}"
keychain="${SCOUT_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
sparkle_sign_update="${SCOUT_SPARKLE_SIGN_UPDATE:-}"
version=""
build_number=""
dry_run=false
bump=true

usage() {
  cat <<EOF
Usage: script/release.sh --version X.Y.Z [--build N] [--no-bump] [--dry-run]

Builds Release, signs with Developer ID and the hardened runtime, notarizes and
staples the app, packages and notarizes a DMG, and writes the update archive.
Output goes to build/release/<version>/. Nothing is installed, opened or published.

Environment:
  SCOUT_SIGN_IDENTITY        default: $identity
  SCOUT_NOTARY_PROFILE       default: $notary_profile
  SCOUT_KEYCHAIN             default: $keychain
  SCOUT_SPARKLE_SIGN_UPDATE  path to Sparkle's sign_update; empty skips the EdDSA step
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --build) build_number="${2:-}"; shift 2 ;;
    --no-bump) bump=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "--version X.Y.Z is required" >&2; exit 2; }

current_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9][0-9]*\) *$/\1/p' "$project_yml" | head -n 1)"
[[ -n "$current_build" ]] || { echo "CURRENT_PROJECT_VERSION not found in $project_yml" >&2; exit 1; }
if [[ -z "$build_number" ]]; then
  build_number=$((current_build + 1))
fi
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo "--build must be an integer" >&2; exit 2; }

out="$root/build/release/$version"
derived="$root/build/release/DerivedData"
app="$out/Scout.app"
app_zip="$out/Scout-$version-notarize.zip"
dmg="$out/Scout-$version.dmg"
update_zip="$out/Scout-$version.zip"
dmg_stage="$out/dmg-stage"
step_no=0

step() {
  step_no=$((step_no + 1))
  printf '\n==> [%02d] %s\n' "$step_no" "$*"
}

run() {
  if [[ "$dry_run" == true ]]; then
    printf '    $'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_to() {
  local dest="$1"
  shift
  if [[ "$dry_run" == true ]]; then
    printf '    $'
    printf ' %q' "$@"
    printf ' > %q\n' "$dest"
  else
    "$@" > "$dest"
  fi
}

notarize() {
  local file="$1" label="$2"
  local result="$out/notary-$label.json"
  local log="$out/notary-$label-log.json"
  if [[ "$dry_run" == true ]]; then
    run_to "$result" xcrun notarytool submit "$file" \
      --keychain-profile "$notary_profile" --keychain "$keychain" \
      --wait --output-format json
    echo "    (read id and status from $result, then fetch the log)"
    run_to "$log" xcrun notarytool log "<submission-id>" \
      --keychain-profile "$notary_profile" --keychain "$keychain"
    return
  fi
  xcrun notarytool submit "$file" \
    --keychain-profile "$notary_profile" --keychain "$keychain" \
    --wait --output-format json > "$result" || true
  local id status
  id="$(plutil -extract id raw -o - "$result")"
  status="$(plutil -extract status raw -o - "$result")"
  echo "$label submission id: $id status: $status"
  echo "$id" > "$out/notary-$label.id"
  xcrun notarytool log "$id" --keychain-profile "$notary_profile" --keychain "$keychain" > "$log"
  [[ "$status" == "Accepted" ]] || { echo "Notarization of $label was $status; see $log" >&2; exit 1; }
}

sign_nested() {
  if [[ "$dry_run" == true ]]; then
    echo "    for each nested bundle or Mach-O under $app/Contents/{Frameworks,XPCServices,Helpers,PlugIns}, deepest first:"
    run codesign --force --timestamp --options runtime --sign "$identity" "<nested-code>"
    return
  fi
  local nested
  while IFS= read -r nested; do
    codesign --force --timestamp --options runtime --sign "$identity" "$nested"
  done < <(
    find "$app/Contents" -depth \
      \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' -o -name '*.dylib' \
         -o \( -type f -perm -u+x -path '*/Frameworks/*' \) \
         -o \( -type f -perm -u+x -path '*/Helpers/*' \) \) \
      ! -path "$app" -print
  )
}

sparkle_sign_archive() {
  if [[ -z "$sparkle_sign_update" ]]; then
    echo "    Sparkle hook: SCOUT_SPARKLE_SIGN_UPDATE is unset, so the EdDSA signature and appcast entry are skipped."
    return
  fi
  run_to "$out/Scout-$version.zip.eddsa" "$sparkle_sign_update" "$update_zip"
}

step "Plan"
cat <<EOF
    version          $version (build $build_number, was $current_build)
    identity         $identity
    team             $team_id
    notary profile   $notary_profile
    keychain         $keychain
    entitlements     $entitlements
    output           $out
    dry run          $dry_run
EOF

step "Preflight: tools, signing identity and notary profile"
run command -v xcodegen
run xcodebuild -version
if [[ "$dry_run" == true ]]; then
  echo "    require exactly '$identity' in:"
  run security find-identity -v -p codesigning "$keychain"
else
  security find-identity -v -p codesigning "$keychain" | grep -Fq "\"$identity\"" \
    || { echo "Signing identity not found in $keychain: $identity" >&2; exit 1; }
fi
run_to /dev/null xcrun notarytool history --keychain-profile "$notary_profile" --keychain "$keychain"

step "Bump version in mac/project.yml"
if [[ "$bump" == true ]]; then
  run perl -pi -e "s/^(\\s*MARKETING_VERSION:\\s*).*/\${1}$version/; s/^(\\s*CURRENT_PROJECT_VERSION:\\s*).*/\${1}$build_number/" "$project_yml"
else
  echo "    skipped (--no-bump)"
fi

step "Prepare output folder"
if [[ -e "$out" ]]; then
  run trash "$out"
fi
run mkdir -p "$out"

step "Generate the Xcode project"
run xcodegen generate --spec "$project_yml" --quiet

step "Build Release"
run xcodebuild \
  -project "$root/mac/Scout.xcodeproj" \
  -scheme Scout \
  -configuration Release \
  -derivedDataPath "$derived" \
  -destination "generic/platform=macOS" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  DEVELOPMENT_TEAM="$team_id" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build
run ditto "$derived/Build/Products/Release/Scout.app" "$app"

step "Sign nested code (Sparkle.framework, XPC services and helpers land here once T4 adds them)"
sign_nested

step "Sign the app with the hardened runtime and entitlements"
run codesign --force --timestamp --options runtime \
  --entitlements "$entitlements" --sign "$identity" "$app"

step "Verify the app signature"
run codesign --verify --strict --deep --verbose=2 "$app"
run_to "$out/entitlements.plist" codesign -d --entitlements :- "$app"
if [[ "$dry_run" == false ]]; then
  if grep -q "get-task-allow" "$out/entitlements.plist"; then
    echo "Signed entitlements contain get-task-allow" >&2
    exit 1
  fi
  codesign -dv --verbose=4 "$app" 2>&1 | grep -E "^(Authority|TeamIdentifier|Runtime|Timestamp|Identifier)" | tee "$out/codesign.txt"
fi

step "Notarize the app"
run ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip"
notarize "$app_zip" app
run trash "$app_zip"

step "Staple the app"
run xcrun stapler staple "$app"
run xcrun stapler validate "$app"

step "Update archive"
run ditto -c -k --sequesterRsrc --keepParent "$app" "$update_zip"
sparkle_sign_archive

step "Package the DMG"
run mkdir -p "$dmg_stage"
run ditto "$app" "$dmg_stage/Scout.app"
run ln -s /Applications "$dmg_stage/Applications"
run hdiutil create -volname Scout -srcfolder "$dmg_stage" -fs HFS+ -format UDZO -ov "$dmg"
run trash "$dmg_stage"
run codesign --force --timestamp --sign "$identity" "$dmg"

step "Notarize the DMG"
notarize "$dmg" dmg

step "Staple the DMG"
run xcrun stapler staple "$dmg"

step "Gatekeeper and stapler checks"
if [[ "$dry_run" == true ]]; then
  run spctl -a -vv -t open --context context:primary-signature "$dmg"
  run spctl -a -vv -t exec "$app"
  run xcrun stapler validate "$dmg"
else
  {
    spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1
    spctl -a -vv -t exec "$app" 2>&1
    xcrun stapler validate "$dmg" 2>&1
  } | tee "$out/verify.txt"
fi

step "Checksums"
if [[ "$dry_run" == true ]]; then
  echo "    (in $out)"
  run_to SHA256SUMS shasum -a 256 "Scout-$version.dmg" "Scout-$version.zip"
else
  (cd "$out" && shasum -a 256 "Scout-$version.dmg" "Scout-$version.zip" > SHA256SUMS)
fi

step "Done"
echo "    $dmg"
echo "    $update_zip"
echo "    Nothing was installed, opened or published. Commit the mac/project.yml version bump separately."
