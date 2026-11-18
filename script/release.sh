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
sparkle_key_command="${SCOUT_SPARKLE_KEY_COMMAND:-}"
sparkle_key_account="${SCOUT_SPARKLE_KEY_ACCOUNT:-ed25519}"
release_base_url="${SCOUT_RELEASE_BASE_URL:-}"
if [[ -z "$release_base_url" ]]; then
  release_base_url='https://github.com/honeybeehq/scout/releases/download/v{version}'
fi
previous_appcast="${SCOUT_PREVIOUS_APPCAST:-}"
minimum_system_version="26.0"
version=""
build_number=""
dry_run=false
bump=true
publish=false
notes=""

usage() {
  cat <<EOF
Usage: script/release.sh --version X.Y.Z [--build N] [--no-bump] [--dry-run]
       [--previous-appcast FILE] [--notes FILE] [--publish]

Builds Release, signs with Developer ID and the hardened runtime, notarizes and
staples the app, packages and notarizes a DMG, writes the update archive, signs it
with Sparkle's EdDSA key and writes appcast.xml. Sparkle is verified against
mac/Sparkle.expected (script/verify-sparkle.sh) before anything is built.
Output goes to build/release/<version>/. Nothing is installed or opened.
--publish (alias --publish-only) verifies and uploads the existing output without
building, bumping, signing or notarizing again. It implies --no-bump.

Environment:
  SCOUT_SIGN_IDENTITY        default: $identity
  SCOUT_NOTARY_PROFILE       default: $notary_profile
  SCOUT_KEYCHAIN             default: $keychain
  SCOUT_RELEASE_BASE_URL     https URL the update zip is downloaded from; {version} is replaced
  SCOUT_SPARKLE_KEY_COMMAND  command that prints the EdDSA private key (e.g. a secret-manager read);
                             empty uses the login keychain, as Sparkle does by default
  SCOUT_SPARKLE_KEY_ACCOUNT  keychain account of the EdDSA key, default: $sparkle_key_account
  SCOUT_SPARKLE_SIGN_UPDATE  default: sign_update from the verified Sparkle artifact
  SCOUT_PREVIOUS_APPCAST     appcast.xml of the last release; its items are kept below the new one
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --build) build_number="${2:-}"; shift 2 ;;
    --publish|--publish-only) publish=true; shift ;;
    --notes) notes="${2:?--notes needs a file}"; shift 2 ;;
    --previous-appcast) previous_appcast="${2:?--previous-appcast needs a file}"; shift 2 ;;
    --no-bump) bump=false; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$publish" == true ]]; then
  bump=false
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "--version X.Y.Z is required" >&2; exit 2; }

current_build="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9][0-9]*\) *$/\1/p' "$project_yml" | head -n 1)"
[[ -n "$current_build" ]] || { echo "CURRENT_PROJECT_VERSION not found in $project_yml" >&2; exit 1; }
if [[ -z "$build_number" ]]; then
  if [[ "$bump" == true ]]; then
    build_number=$((current_build + 1))
  else
    build_number="$current_build"
  fi
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
    run codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$identity" "<nested-code>"
    return
  fi
  local nested
  while IFS= read -r nested; do
    codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$identity" "$nested"
  done < <(
    find "$app/Contents" -depth \
      \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' -o -name '*.appex' -o -name '*.dylib' \
         -o \( -type f -perm -u+x -path '*/Frameworks/*' \) \
         -o \( -type f -perm -u+x -path '*/Helpers/*' \) \) \
      ! -path "$app" -print
  )
}

project_setting() {
  sed -n "s/^ *$1: *\"\{0,1\}\([^\"]*\)\"\{0,1\} *\$/\1/p" "$project_yml" | head -n 1
}

sparkle_tool() {
  if [[ -n "$sparkle_sign_update" && "$1" == sign_update ]]; then
    echo "$sparkle_sign_update"
    return
  fi
  if [[ "$dry_run" == true ]]; then
    echo "$derived/SourcePackages/artifacts/<sparkle>/bin/$1"
    return
  fi
  local tool
  tool="$(find "$derived/SourcePackages/artifacts" -type f -name "$1" -path '*/bin/*' -print | head -n 1)"
  [[ -n "$tool" ]] || { echo "Sparkle's $1 not found under $derived/SourcePackages/artifacts" >&2; exit 1; }
  echo "$tool"
}

sparkle_sign_archive() {
  local tool signature_file="$out/Scout-$version.zip.eddsa"
  tool="$(sparkle_tool sign_update)"
  if [[ -n "$sparkle_key_command" ]]; then
    if [[ "$dry_run" == true ]]; then
      echo "    \$ <SCOUT_SPARKLE_KEY_COMMAND> | $(printf '%q' "$tool") --ed-key-file - $(printf '%q' "$update_zip") > $(printf '%q' "$signature_file")"
      return
    fi
    bash -c "$sparkle_key_command" | "$tool" --ed-key-file - "$update_zip" > "$signature_file"
  else
    run_to "$signature_file" "$tool" --account "$sparkle_key_account" "$update_zip"
  fi
}

write_appcast() {
  local appcast="$out/appcast.xml"
  local url="${release_base_url//\{version\}/$version}"
  url="${url%/}/Scout-$version.zip"
  if [[ "$dry_run" == true ]]; then
    echo "    read sparkle:edSignature and length from $out/Scout-$version.zip.eddsa"
    echo "    write $appcast:"
    echo "      item $version (build $build_number), minimumSystemVersion $minimum_system_version"
    echo "      enclosure $url"
    if [[ -n "$previous_appcast" ]]; then
      echo "      then the items of $previous_appcast"
    fi
    run xmllint --noout "$appcast"
    return
  fi
  local signed ed_signature length
  signed="$(cat "$out/Scout-$version.zip.eddsa")"
  ed_signature="$(printf '%s' "$signed" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  length="$(printf '%s' "$signed" | sed -n 's/.*length="\([0-9]*\)".*/\1/p')"
  [[ -n "$ed_signature" && -n "$length" ]] || { echo "sign_update gave no signature: $signed" >&2; exit 1; }
  [[ "$length" == "$(stat -f %z "$update_zip")" ]] || { echo "sign_update length $length does not match $update_zip" >&2; exit 1; }
  local previous_items=""
  if [[ -n "$previous_appcast" ]]; then
    if grep -q "<sparkle:version>$build_number</sparkle:version>" "$previous_appcast"; then
      echo "$previous_appcast already has build $build_number" >&2
      exit 1
    fi
    previous_items="$(awk '/<item>/{keep=1} keep{print} /<\/item>/{keep=0}' "$previous_appcast")"
  fi
  {
    cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Scout</title>
    <item>
      <title>Version $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum_system_version</sparkle:minimumSystemVersion>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$ed_signature"/>
    </item>
XML
    if [[ -n "$previous_items" ]]; then
      printf '%s\n' "$previous_items"
    fi
    cat <<XML
  </channel>
</rss>
XML
  } > "$appcast"
  xmllint --noout "$appcast"
}

step "Preflight: clean source checkout"
if [[ "$dry_run" == true ]]; then
  run git -C "$root" status --porcelain --untracked-files=all
  echo "    require an empty working tree before starting"
else
  [[ -z "$(git -C "$root" status --porcelain --untracked-files=all)" ]] \
    || { echo "Release requires a clean working tree; commit or remove local changes first" >&2; exit 1; }
fi
if [[ "$bump" == false ]]; then
  if [[ "$dry_run" == true ]]; then
    echo "    require committed MARKETING_VERSION=$version and CURRENT_PROJECT_VERSION=$build_number"
  else
    [[ "$(project_setting MARKETING_VERSION)" == "$version" && "$current_build" == "$build_number" ]] \
      || { echo "--no-bump requires the requested version and build to match mac/project.yml" >&2; exit 1; }
  fi
fi

step "Plan"
cat <<EOF
    version          $version (build $build_number, was $current_build)
    identity         $identity
    team             $team_id
    notary profile   $notary_profile
    keychain         $keychain
    entitlements     $entitlements
    sparkle          $(awk '/^  [^ ]/{in_sparkle=($1=="Sparkle:")} in_sparkle && $1=="exactVersion:"{print $2}' "$project_yml"), checked against mac/Sparkle.expected
    other packages   checked against mac/Packages.allowed
    feed             $(project_setting SCOUT_FEED_URL)
    download base    ${release_base_url:-<unset>}
    EdDSA key        $([[ -n "$sparkle_key_command" ]] && echo "SCOUT_SPARKLE_KEY_COMMAND" || echo "login keychain, account $sparkle_key_account")
    output           $out
    dry run          $dry_run
EOF

if [[ "$publish" == false ]]; then
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

step "Preflight: Sparkle feed, public key, download URL and EdDSA key"
feed_url="$(project_setting SCOUT_FEED_URL)"
public_key="$(project_setting SCOUT_SPARKLE_PUBLIC_KEY)"
if [[ "$dry_run" == true ]]; then
  echo "    require SCOUT_FEED_URL (https) and SCOUT_SPARKLE_PUBLIC_KEY in mac/project.yml, now: '${feed_url}' / '${public_key}'"
  echo "    require SCOUT_RELEASE_BASE_URL (https), now: '${release_base_url}'"
else
  [[ "$feed_url" == https://* ]] || { echo "Set SCOUT_FEED_URL in mac/project.yml to the https appcast URL" >&2; exit 1; }
  [[ -n "$public_key" ]] || { echo "Set SCOUT_SPARKLE_PUBLIC_KEY in mac/project.yml (generate_keys -p on the signing host)" >&2; exit 1; }
  [[ "$release_base_url" == https://* ]] || { echo "SCOUT_RELEASE_BASE_URL must be an https URL" >&2; exit 1; }
fi
if [[ -z "$sparkle_key_command" ]]; then
  run_to /dev/null security find-generic-password -s https://sparkle-project.org -a "$sparkle_key_account" "$keychain"
fi

step "Bump version in mac/project.yml"
if [[ "$bump" == true ]]; then
  run perl -pi -e "s/^(\\s*MARKETING_VERSION:\\s*).*/\${1}$version/; s/^(\\s*CURRENT_PROJECT_VERSION:\\s*).*/\${1}$build_number/" "$project_yml"
  run git -C "$root" add -- mac/project.yml
  run git -C "$root" commit -m "Release $version (build $build_number)"
else
  echo "    skipped (--no-bump)"
fi
source_sha="$(git -C "$root" rev-parse HEAD)"
if [[ "$dry_run" == true && "$bump" == true ]]; then
  source_sha='<version-bump-commit-sha>'
fi
echo "    source commit $source_sha"

step "Prepare output folder"
if [[ -e "$out" ]]; then
  run trash "$out"
fi
run mkdir -p "$out"

step "Generate the Xcode project"
run xcodegen generate --spec "$project_yml" --quiet

step "Resolve Swift packages"
run xcodebuild -resolvePackageDependencies \
  -project "$root/mac/Scout.xcodeproj" \
  -scheme Scout \
  -derivedDataPath "$derived"

step "Verify packages: Sparkle against mac/Sparkle.expected, every other pin against mac/Packages.allowed"
run "$root/script/verify-sparkle.sh" --derived "$derived"

step "Check the EdDSA key matches the public key in mac/project.yml"
if [[ -n "$sparkle_key_command" ]]; then
  echo "    skipped: the key comes from SCOUT_SPARKLE_KEY_COMMAND; sign_update and Sparkle's runtime verification cover it"
elif [[ "$dry_run" == true ]]; then
  run "$(sparkle_tool generate_keys)" --account "$sparkle_key_account" -p
else
  generate_keys="$(sparkle_tool generate_keys)"
  keychain_public_key="$("$generate_keys" --account "$sparkle_key_account" -p)"
  [[ "$keychain_public_key" == "$public_key" ]] \
    || { echo "The keychain's EdDSA public key differs from SCOUT_SPARKLE_PUBLIC_KEY" >&2; exit 1; }
fi

step "Verify build source"
if [[ "$dry_run" == true ]]; then
  echo "    require clean HEAD=$source_sha after project generation and package resolution"
else
  [[ "$(git -C "$root" rev-parse HEAD)" == "$source_sha" && -z "$(git -C "$root" status --porcelain --untracked-files=all)" ]] \
    || { echo "Build source changed after the release commit; review and commit the changes, then restart" >&2; exit 1; }
fi

step "Build Release"
run xcodebuild \
  -project "$root/mac/Scout.xcodeproj" \
  -scheme Scout \
  -configuration Release \
  -derivedDataPath "$derived" \
  -destination "generic/platform=macOS" \
  -quiet \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
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

step "Sign nested code (Sparkle.framework, its XPC services, Autoupdate and Updater.app)"
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
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
if [[ "$dry_run" == true ]]; then
  echo "    require TeamIdentifier=$team_id on the re-signed Sparkle.framework:"
  run codesign -dv --verbose=2 "$sparkle_framework"
else
  sparkle_team="$(codesign -dv --verbose=2 "$sparkle_framework" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$sparkle_team" == "$team_id" ]] \
    || { echo "Embedded Sparkle.framework has TeamIdentifier '${sparkle_team:-none}', expected $team_id" >&2; exit 1; }
  echo "Sparkle.framework TeamIdentifier=$sparkle_team" | tee -a "$out/codesign.txt"
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

step "Sign the update archive with Sparkle's EdDSA key"
sparkle_sign_archive

step "Seed appcast history"
if [[ -n "$previous_appcast" ]]; then
  run xmllint --noout "$previous_appcast"
else
  previous_appcast="$out/previous-appcast/appcast.xml"
  run mkdir -p "$out/previous-appcast"
  if [[ "$dry_run" == true ]]; then
    run gh release download --repo honeybeehq/scout --pattern appcast.xml --dir "$out/previous-appcast"
    echo "    If download fails, require an empty published-release list; otherwise stop."
    run gh release list --repo honeybeehq/scout --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq length
  elif ! gh release download --repo honeybeehq/scout --pattern appcast.xml --dir "$out/previous-appcast"; then
    release_count="$(gh release list --repo honeybeehq/scout --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq length)"
    [[ "$release_count" == 0 ]] || { echo "Could not retrieve the published appcast; use --previous-appcast FILE" >&2; exit 1; }
    previous_appcast=""
  fi
  if [[ -n "$previous_appcast" ]]; then
    run xmllint --noout "$previous_appcast"
  fi
fi

step "Write appcast.xml"
write_appcast

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
    spctl -a -vv -t open --context context:primary-signature "$dmg" 2>&1 || exit 1
    spctl -a -vv -t exec "$app" 2>&1 || exit 1
    xcrun stapler validate "$dmg" 2>&1
  } | tee "$out/verify.txt"
fi

step "Record source commit"
if [[ "$dry_run" == true ]]; then
  echo "    append Source commit: $source_sha to $out/verify.txt"
else
  printf '\nSource commit: %s\n' "$source_sha" >> "$out/verify.txt"
fi

step "Checksums"
if [[ "$dry_run" == true ]]; then
  echo "    (in $out)"
  run_to SHA256SUMS shasum -a 256 "Scout-$version.dmg" "Scout-$version.zip" appcast.xml
else
  (cd "$out" && shasum -a 256 "Scout-$version.dmg" "Scout-$version.zip" appcast.xml > SHA256SUMS)
fi

else
  source_sha="$(git -C "$root" rev-parse HEAD)"
  step "Verify existing release source and files"
  for file in "$out/verify.txt" "$out/SHA256SUMS" "$dmg" "$update_zip" "$out/appcast.xml" "$app/Contents/Info.plist"; do
    run test -f "$file" || { echo "Required verified release file is missing: $file" >&2; exit 1; }
  done
  if [[ "$dry_run" == true ]]; then
    echo "    require exactly Source commit: $source_sha in $out/verify.txt"
    echo "    require existing app version $version and build $build_number"
  else
    recorded_source="$(sed -n 's/^Source commit: //p' "$out/verify.txt")"
    [[ "$recorded_source" == "$source_sha" ]] \
      || { echo "Existing release source does not match HEAD; rebuild and verify from this commit first" >&2; exit 1; }
    [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" == "$version" \
      && "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" == "$build_number" ]] \
      || { echo "Existing app version/build does not match the committed release" >&2; exit 1; }
  fi

  step "Recompute and compare release checksums"
  if [[ "$dry_run" == true ]]; then
    echo "    (in $out)"
    run shasum -a 256 "Scout-$version.dmg" "Scout-$version.zip" appcast.xml
    echo "    compare this output byte-for-byte with SHA256SUMS; stop on any mismatch"
  else
    existing_sums="$(cat "$out/SHA256SUMS")"
    actual_sums="$(cd "$out" && shasum -a 256 "Scout-$version.dmg" "Scout-$version.zip" appcast.xml)"
    [[ "$actual_sums" == "$existing_sums" ]] \
      || { echo "Release checksums changed; refusing to publish" >&2; exit 1; }
  fi

  step "Recheck existing signatures, Gatekeeper and stapled tickets"
  run codesign --verify --strict --deep --verbose=2 "$app"
  run codesign --verify --strict --verbose=2 "$dmg"
  run spctl -a -vv -t exec "$app"
  run spctl -a -vv -t open --context context:primary-signature "$dmg"
  run xcrun stapler validate "$app"
  run xcrun stapler validate "$dmg"
  run xmllint --noout "$out/appcast.xml"
fi

step "Release notes"
release_notes="$out/release-notes.md"
if [[ -n "$notes" ]]; then
  run test -f "$notes"
  run cp "$notes" "$release_notes"
elif [[ "$dry_run" == true ]]; then
  echo "    write $release_notes: Scout $version for macOS $minimum_system_version or later; installation and update instructions"
else
  printf 'Scout %s for macOS %s or later.\n\nDownload the DMG and drag Scout into Applications. Existing installations can use Check for Updates… or daily automatic checks.\n' "$version" "$minimum_system_version" > "$release_notes"
fi
if [[ "$dry_run" == true ]]; then
  echo "    append Source commit: $source_sha to $release_notes"
else
  printf '\nSource commit: %s\n' "$source_sha" >> "$release_notes"
fi

step "Publish (opt-in)"
if [[ "$publish" == true ]]; then
  run git -C "$root" fetch origin --prune
  if [[ "$dry_run" == true ]]; then
    run git -C "$root" status --porcelain --untracked-files=all
    run git -C "$root" branch -r --contains "$source_sha" --list 'origin/*'
    echo "    require clean HEAD=$source_sha and a containing origin branch"
    echo "    if missing: git -C $(printf '%q' "$root") push origin HEAD; land the bump, then build and verify from the landed commit before --version $version --publish"
  else
    [[ "$(git -C "$root" rev-parse HEAD)" == "$source_sha" && -z "$(git -C "$root" status --porcelain --untracked-files=all)" ]] \
      || { echo "Publishing requires unchanged, clean HEAD at $source_sha" >&2; exit 1; }
    if [[ -z "$(git -C "$root" branch -r --contains HEAD --list 'origin/*')" ]]; then
      echo "Push this commit first: $source_sha" >&2
      printf '  git -C %q push origin HEAD\n' "$root" >&2
      echo "Land the bump commit, build and verify from the landed commit, then run:" >&2
      printf '  script/release.sh --version %q --build %q --no-bump --publish\n' "$version" "$build_number" >&2
      exit 1
    fi
  fi
  if [[ "$dry_run" == true ]]; then
    run gh repo view honeybeehq/scout --json visibility --jq .visibility
    echo "    require PUBLIC and all verification steps to pass in this run"
    run gh api "repos/honeybeehq/scout/git/matching-refs/tags/v$version" --jq "[.[] | select(.ref == \"refs/tags/v$version\")] | length"
    echo "    require zero matching tags"
  else
    [[ "$(gh repo view honeybeehq/scout --json visibility --jq .visibility)" == PUBLIC ]] \
      || { echo "Publishing requires a PUBLIC repository" >&2; exit 1; }
    tag_count="$(gh api "repos/honeybeehq/scout/git/matching-refs/tags/v$version" --jq "[.[] | select(.ref == \"refs/tags/v$version\")] | length")"
    [[ "$tag_count" == 0 ]] || { echo "Tag v$version already exists" >&2; exit 1; }
  fi
  run gh release create "v$version" --repo honeybeehq/scout --target "$source_sha" \
    --title "Scout $version" --notes-file "$release_notes" \
    "$dmg" "$update_zip" "$out/appcast.xml" "$out/SHA256SUMS"
else
  echo "    skipped (use --publish to upload verified assets)"
fi

step "Done"
echo "    $dmg"
echo "    $update_zip"
echo "    $out/appcast.xml"
echo "    Nothing was installed or opened. Publish requested: $publish. Source commit: $source_sha. Push and land the bump before publishing."
