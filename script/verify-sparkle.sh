#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project_yml="$root/mac/project.yml"
expected_file="$root/mac/Sparkle.expected"
resolved="$root/mac/Scout.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
derived="$root/build/release/DerivedData"
record=false

usage() {
  cat <<USAGE
Usage: script/verify-sparkle.sh [--derived DIR] [--record]

Run on the Mac Studio after:
  xcodebuild -resolvePackageDependencies -project mac/Scout.xcodeproj -derivedDataPath DIR

Checks that Package.resolved pins only Sparkle, at the exact version in mac/project.yml
and the revision in mac/Sparkle.expected; that the checked-out Package.swift declares the
expected binary checksum; that the SHA-256 of the resolved Sparkle artifact tree matches;
and that Sparkle.framework is validly signed by the expected Team ID.

--record writes what it sees into mac/Sparkle.expected instead of comparing. A human
reviews that diff and commits it. Until then every check fails.

Default DIR: $derived
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived) derived="${2:-}"; shift 2 ;;
    --record) record=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "verify-sparkle: $*" >&2; exit 1; }

expected() {
  sed -n "s/^$1=//p" "$expected_file" | head -n 1
}

tree_sha256() {
  (
    cd "$1"
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then
        printf 'L %s %s\n' "$path" "$(readlink "$path")"
      else
        printf 'F %s %s\n' "$path" "$(shasum -a 256 < "$path" | cut -d' ' -f1)"
      fi
    done
  ) | shasum -a 256 | cut -d' ' -f1
}

pinned_version="$(sed -n 's/^ *exactVersion: *\([0-9][0-9.]*\) *$/\1/p' "$project_yml")"
[[ "$(printf '%s\n' "$pinned_version" | grep -c .)" == 1 ]] || fail "expected one exactVersion in $project_yml, found: ${pinned_version:-none}"
[[ -f "$resolved" ]] || fail "no Package.resolved at $resolved; run xcodebuild -resolvePackageDependencies first"
[[ -f "$expected_file" ]] || fail "missing $expected_file"

pins=0
sparkle_index=""
while plutil -extract "pins.$pins.identity" raw -o - "$resolved" >/dev/null 2>&1; do
  identity="$(plutil -extract "pins.$pins.identity" raw -o - "$resolved")"
  [[ "$identity" == "sparkle" ]] && sparkle_index="$pins"
  pins=$((pins + 1))
done
[[ -n "$sparkle_index" ]] || fail "Package.resolved has no sparkle pin"
[[ "$pins" == 1 ]] || fail "Package.resolved pins $pins remote packages; Sparkle is the only allowed one"

location="$(plutil -extract "pins.$sparkle_index.location" raw -o - "$resolved")"
resolved_version="$(plutil -extract "pins.$sparkle_index.state.version" raw -o - "$resolved" 2>/dev/null || true)"
resolved_revision="$(plutil -extract "pins.$sparkle_index.state.revision" raw -o - "$resolved")"
[[ "${location%.git}" == "https://github.com/sparkle-project/Sparkle" ]] || fail "unexpected Sparkle location: $location"
[[ "$resolved_version" == "$pinned_version" ]] || fail "Package.resolved has Sparkle ${resolved_version:-without a version}, project.yml pins $pinned_version"

checkout="$derived/SourcePackages/checkouts/Sparkle"
[[ -d "$checkout" ]] || fail "no Sparkle checkout at $checkout"
checkout_revision="$(git -C "$checkout" rev-parse HEAD)"
[[ "$checkout_revision" == "$resolved_revision" ]] || fail "checkout is at $checkout_revision, Package.resolved says $resolved_revision"
binary_checksums="$(grep -i 'checksum' "$checkout/Package.swift" | grep -Eo '[0-9a-f]{64}' | sort -u || true)"
[[ "$(printf '%s\n' "$binary_checksums" | grep -c .)" == 1 ]] || fail "expected one binaryTarget checksum in $checkout/Package.swift, found: ${binary_checksums:-none}"

xcframeworks="$(find "$derived/SourcePackages/artifacts" -type d -name Sparkle.xcframework -prune -print 2>/dev/null || true)"
[[ "$(printf '%s\n' "$xcframeworks" | grep -c .)" == 1 ]] || fail "expected one Sparkle.xcframework under $derived/SourcePackages/artifacts, found: ${xcframeworks:-none}"
artifact_dir="$(dirname "$xcframeworks")"
artifact_sha256="$(tree_sha256 "$artifact_dir")"

framework="$(find "$xcframeworks" -maxdepth 2 -path '*macos*' -type d -name Sparkle.framework -print | head -n 1)"
[[ -n "$framework" ]] || fail "no macOS Sparkle.framework inside $xcframeworks"
codesign --verify --strict --deep "$framework" || fail "codesign --verify failed for $framework"
signature="$(codesign -dv --verbose=2 "$framework" 2>&1)"
team_id="$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p')"
[[ -n "$team_id" && "$team_id" != "not set" ]] || fail "Sparkle.framework has no Team ID"

cat <<REPORT
Sparkle          $pinned_version from $location
revision         $resolved_revision
binary checksum  $binary_checksums
artifact         $artifact_dir
artifact sha256  $artifact_sha256
framework        $framework
$(printf '%s\n' "$signature" | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp)=' | sed 's/^/codesign         /')
REPORT

if [[ "$record" == true ]]; then
  printf 'revision=%s\nbinary_checksum=%s\nartifact_sha256=%s\nteam_id=%s\n' \
    "$resolved_revision" "$binary_checksums" "$artifact_sha256" "$team_id" > "$expected_file"
  echo
  echo "Recorded into $expected_file. Compare these values with Sparkle's $pinned_version release notes, then have a human approve and commit the diff:"
  git -C "$root" diff -- "$expected_file" || true
  exit 0
fi

status=0
check() {
  local name="$1" actual="$2" want
  want="$(expected "$name")"
  if [[ -z "$want" ]]; then
    echo "MISSING  $name has no approved value in mac/Sparkle.expected (run --record, review, commit)" >&2
    status=1
  elif [[ "$want" != "$actual" ]]; then
    echo "MISMATCH $name: expected $want, got $actual" >&2
    status=1
  else
    echo "OK       $name"
  fi
}
check revision "$resolved_revision"
check binary_checksum "$binary_checksums"
check artifact_sha256 "$artifact_sha256"
check team_id "$team_id"
[[ "$status" == 0 ]] || fail "Sparkle $pinned_version is not verified"
echo "Sparkle $pinned_version verified."
