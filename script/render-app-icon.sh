#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d)"
xcrun swiftc -parse-as-library -O \
  "$root/script/AppIconRenderer.swift" \
  "$root/mac/Scout/Design/ScoutMark.swift" \
  "$root/mac/Scout/Design/Palette.swift" \
  "$root/mac/Scout/Design/Motion.swift" \
  -o "$build/render-app-icon"
"$build/render-app-icon" "$root/mac/Scout/Resources/Assets.xcassets/AppIcon.appiconset"
echo "Rendered app icon into mac/Scout/Resources/Assets.xcassets/AppIcon.appiconset"
