#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
staged="${SCOUT_STAGED_APP:-$HOME/Applications/Scout.app}"
derived="$root/build/DerivedData"
configuration="${SCOUT_CONFIGURATION:-Debug}"
launch_args=()
build_only=false

for arg in "$@"; do
  case "$arg" in
    --build-only) build_only=true ;;
    *) launch_args+=("$arg") ;;
  esac
done

cd "$root/mac"
xcodegen generate --quiet
xcodebuild \
  -project Scout.xcodeproj \
  -scheme Scout \
  -configuration "$configuration" \
  -derivedDataPath "$derived" \
  -destination "platform=macOS,arch=arm64" \
  -quiet \
  build

built="$derived/Build/Products/$configuration/Scout.app"
pkill -x Scout 2>/dev/null || true
mkdir -p "$(dirname "$staged")"
rsync -a --delete "$built/" "$staged/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$staged"
codesign --verify --strict "$staged"
echo "Staged $staged"

if [[ "$build_only" == false ]]; then
  open -n "$staged" --args ${launch_args[@]+"${launch_args[@]}"}
fi
