#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$root/sdk/web"
bundle="$sdk/packages/web/dist/index.js"
destination="${1:?Pass the app resource destination for scout.js}"
export PATH="$HOME/Library/pnpm:$HOME/.local/bin:/opt/homebrew/bin:$PATH"

cd "$sdk"
rebuild=false
if [[ ! -f "$bundle" ]]; then
  rebuild=true
elif [[ -n "$(find packages/web/src scripts/build.mjs packages/web/package.json packages/web/tsconfig.json pnpm-lock.yaml -type f -newer "$bundle" -print -quit)" ]]; then
  rebuild=true
fi
if [[ "$rebuild" == true ]]; then
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "Scout's browser SDK needs pnpm: install the packageManager version from sdk/web/package.json, then rebuild Scout." >&2
    exit 1
  fi
  if [[ ! -d node_modules ]]; then
    pnpm install --frozen-lockfile
  fi
  pnpm build
fi
mkdir -p "$(dirname "$destination")"
cp "$bundle" "$destination"
echo "Bundled Scout browser SDK: $destination"
