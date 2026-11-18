#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: script/record-hero.sh <Scout.app built with a non-release bundle id> [--patch <dir>] [--work <dir>]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
app="$1"
shift
patch=""
work="/tmp/scout-hero"
while [ $# -gt 0 ]; do
  case "$1" in
    --patch) patch="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    *) usage ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id="$(defaults read "$app/Contents/Info" CFBundleIdentifier)"
if [ "$bundle_id" = "com.trmdy.scout" ]; then
  echo "refusing to run with the release bundle id; build with PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.hero" >&2
  exit 1
fi
if [ -e "$work" ]; then
  echo "$work exists; move it away first" >&2
  exit 1
fi

line1="${HERO_LINE1:-Make this button the primary color, and make it full width.}"
line2="${HERO_LINE2:-This headline is way too long. Change it to: Dinner, planned together.}"
lead=1.8
gap=2.8
port="${HERO_PORT:-8411}"
frame="${HERO_SAFARI_FRAME:-0,25,1920,1055}"

mkdir -p "$work/out"
cp -R "$root/Fixtures/landing-demo-site" "$work/site"
git -C "$work/site" init -q -b main
git -C "$work/site" add -A
git -C "$work/site" -c user.name=Demo -c user.email=demo@example.invalid commit -q -m "Larder plans page"

seconds() { afinfo "$1" | awk '/estimated duration/ { print $3 }'; }
say -o "$work/line1.aiff" "$line1"
say -o "$work/line2.aiff" "$line2"
d1="$(seconds "$work/line1.aiff")"
d2="$(seconds "$work/line2.aiff")"
lead_ms="$(python3 -c "print(int($lead * 1000))")"
gap_ms="$(python3 -c "print(int($gap * 1000))")"
say -o "$work/narration.aiff" "[[slnc $lead_ms]] $line1 [[slnc $gap_ms]] $line2 [[slnc 3000]]"
echo "speech: lead $lead, line 1 $d1 s, gap $gap, line 2 $d2 s"

defaults write "$bundle_id" onboarding.complete -bool true
defaults write "$bundle_id" delivery.autoSend -bool false
defaults write "$bundle_id" review.opening -string always
pbpaste > "$work/clipboard.txt" || true

caffeinate -dimsu -w $$ &
(cd "$work/site" && exec python3 -m http.server "$port" --bind 127.0.0.1 > "$work/server.log" 2>&1) &
server=$!

safari_was_running=false
pgrep -x Safari > /dev/null && safari_was_running=true
open -a Safari "http://127.0.0.1:$port/"
sleep 5

if [ -n "$patch" ]; then
  (
    while [ ! -e "$work/out/waiting-for-patch" ]; do sleep 1; done
    mkdir -p "$work/out/patch/files"
    cp "$patch"/* "$work/out/patch/files/"
    touch "$work/out/patch/ready"
  ) &
fi

set +e
"$app/Contents/MacOS/Scout" \
  --hero-demo="$work/out" \
  --hero-audio="$work/narration.aiff" \
  --hero-site="$work/site" \
  --hero-timing="$lead,$d1,$gap,$d2" \
  --hero-safari-frame="$frame" \
  --data-root="$work/data" \
  --live-delivery \
  --appearance=dark \
  > "$work/scout.log" 2>&1
status=$?
set -e

kill "$server" 2>/dev/null || true
if [ "$safari_was_running" = false ]; then
  pkill -x Safari 2>/dev/null || true
fi
pbcopy < "$work/clipboard.txt" || true
defaults delete "$bundle_id" 2>/dev/null || true
cp "$work/narration.aiff" "$work/out/"
printf '%s\n%s\n%s,%s,%s,%s\n' "$line1" "$line2" "$lead" "$d1" "$gap" "$d2" > "$work/out/speech.txt"
git -C "$work/site" diff > "$work/out/site.diff" || true
echo "Scout exited with $status; recording in $work/out"
