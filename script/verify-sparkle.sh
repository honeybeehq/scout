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
and that Sparkle.framework passes codesign --verify with the expected signature state
(Sparkle's SPM artifact is ad-hoc signed, so there is no Team ID) and CDHash.

--record gathers every value first and writes it into mac/Sparkle.expected, then reports
any problem it found. A human reviews that diff and commits it. Until then every check fails.

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

problems=()
problem() { problems+=("$*"); }

pins=0
sparkle_index=""
while plutil -extract "pins.$pins.identity" raw -o - "$resolved" >/dev/null 2>&1; do
  identity="$(plutil -extract "pins.$pins.identity" raw -o - "$resolved")"
  [[ "$identity" == "sparkle" ]] && sparkle_index="$pins"
  pins=$((pins + 1))
done
[[ -n "$sparkle_index" ]] || fail "Package.resolved has no sparkle pin"
[[ "$pins" == 1 ]] || problem "Package.resolved pins $pins remote packages; Sparkle is the only allowed one"

location="$(plutil -extract "pins.$sparkle_index.location" raw -o - "$resolved")"
resolved_version="$(plutil -extract "pins.$sparkle_index.state.version" raw -o - "$resolved" 2>/dev/null || true)"
resolved_revision="$(plutil -extract "pins.$sparkle_index.state.revision" raw -o - "$resolved")"
[[ "${location%.git}" == "https://github.com/sparkle-project/Sparkle" ]] || problem "unexpected Sparkle location: $location"
[[ "$resolved_version" == "$pinned_version" ]] || problem "Package.resolved has Sparkle ${resolved_version:-without a version}, project.yml pins $pinned_version"

checkout="$derived/SourcePackages/checkouts/Sparkle"
checkout_revision="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || echo "no checkout at $checkout")"
[[ "$checkout_revision" == "$resolved_revision" ]] || problem "checkout is at $checkout_revision, Package.resolved says $resolved_revision"
binary_checksum="$(grep -i 'checksum' "$checkout/Package.swift" 2>/dev/null | grep -Eo '[0-9a-f]{64}' | sort -u || true)"
[[ "$(printf '%s\n' "$binary_checksum" | grep -c .)" == 1 ]] || problem "expected one binaryTarget checksum in $checkout/Package.swift, found: ${binary_checksum:-none}"

xcframeworks="$(find "$derived/SourcePackages/artifacts" -type d -name Sparkle.xcframework -prune -print 2>/dev/null || true)"
[[ "$(printf '%s\n' "$xcframeworks" | grep -c .)" == 1 ]] || fail "expected one Sparkle.xcframework under $derived/SourcePackages/artifacts, found: ${xcframeworks:-none}"
artifact_dir="$(dirname "$xcframeworks")"
artifact_sha256="$(tree_sha256 "$artifact_dir")"

framework="$(find "$xcframeworks" -maxdepth 2 -path '*macos*' -type d -name Sparkle.framework -print | head -n 1)"
[[ -n "$framework" ]] || fail "no macOS Sparkle.framework inside $xcframeworks"
signature="$(codesign -dv --verbose=4 "$framework" 2>&1 || true)"
if printf '%s\n' "$signature" | grep -q '^Signature=adhoc'; then
  signature_state="adhoc"
else
  signature_state="$(printf '%s\n' "$signature" | sed -n 's/^Authority=//p' | head -n 1)"
fi
cdhash="$(printf '%s\n' "$signature" | sed -n 's/^CDHash=//p' | head -n 1)"
[[ -n "$signature_state" ]] || problem "Sparkle.framework has no readable signature"
[[ -n "$cdhash" ]] || problem "Sparkle.framework has no CDHash"
codesign_verify="$(codesign --verify --strict --deep "$framework" 2>&1)" || problem "codesign --verify failed for $framework: $codesign_verify"

cat <<REPORT
Sparkle          $pinned_version from $location
revision         $resolved_revision
binary checksum  ${binary_checksum:-none}
artifact         $artifact_dir
artifact sha256  $artifact_sha256
framework        $framework
signature        ${signature_state:-none}
cdhash           ${cdhash:-none}
$(printf '%s\n' "$signature" | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|Timestamp)=' | sed 's/^/codesign         /')
REPORT

report_problems() {
  local item
  for item in "${problems[@]}"; do
    echo "PROBLEM  $item" >&2
  done
}

if [[ "$record" == true ]]; then
  printf 'revision=%s\nbinary_checksum=%s\nartifact_sha256=%s\nsignature=%s\ncdhash=%s\n' \
    "$resolved_revision" "$binary_checksum" "$artifact_sha256" "$signature_state" "$cdhash" > "$expected_file"
  echo
  echo "Recorded into $expected_file. Compare these values with Sparkle's $pinned_version release, then have a human approve and commit the diff:"
  git -C "$root" --no-pager diff -- "$expected_file" || true
  if [[ "${#problems[@]}" -gt 0 ]]; then
    report_problems
    fail "recorded, but the problems above must be resolved before Sparkle $pinned_version can verify"
  fi
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
check binary_checksum "$binary_checksum"
check artifact_sha256 "$artifact_sha256"
check signature "$signature_state"
check cdhash "$cdhash"
if [[ "${#problems[@]}" -gt 0 ]]; then
  report_problems
  status=1
fi
[[ "$status" == 0 ]] || fail "Sparkle $pinned_version is not verified"
echo "Sparkle $pinned_version verified."
