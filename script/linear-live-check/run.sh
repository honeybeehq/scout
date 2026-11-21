#!/bin/bash
set -uo pipefail
if [ $# -ne 1 ]; then echo "usage: SCOUT_APP=<Scout binary> SCOUT_DEMO_VIDEO=<mp4> run.sh <test-team-id>   (key in SCOUT_LINEAR_KEY or on stdin)" >&2; exit 2; fi
TEAM=$1
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${SCOUT_LIVE_OUT:-$PWD/linear-live-out}
APP=${SCOUT_APP:?set SCOUT_APP to the Debug Scout.app/Contents/MacOS/Scout}
VIDEO=${SCOUT_DEMO_VIDEO:?set SCOUT_DEMO_VIDEO to any short mp4}
KEY=${SCOUT_LINEAR_KEY:-}
unset SCOUT_LINEAR_KEY
if [ -z "$KEY" ]; then IFS= read -r KEY; fi
if [ -z "$KEY" ]; then echo "no key" >&2; exit 2; fi
if [ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then echo "$OUT is not empty; use a fresh SCOUT_LIVE_OUT" >&2; exit 2; fi
mkdir -p "$OUT"
feed() { printf '%s\n' "$KEY"; }
RUN=scout-live-$(date +%Y%m%d%H%M%S)
SESSION=$OUT/session

finish() {
  echo "== cleanup: archive every issue this run created (test team only)"
  feed | python3 -I "$HERE/live.py" cleanup "$TEAM" "$OUT"
  echo "== key check over $OUT"
  BODY=${KEY#lin_api_}
  LEAKS=$( { grep -rlF -f <(printf '%s\n%s\n' "$KEY" "$BODY") "$OUT" 2>/dev/null || true; } )
  unset KEY BODY
  if [ -n "$LEAKS" ]; then
    echo "KEY MATERIAL FOUND, do not share these files:" >&2
    echo "$LEAKS" >&2
    exit 3
  fi
  echo "no key material in $OUT"
}
trap finish EXIT

defaults delete com.trmdy.scout.linear-demo >/dev/null 2>&1 || true
echo "== API checks"
feed | python3 -I "$HERE/live.py" check "$TEAM" "$OUT" || echo "API checks stopped early (see api.log)"

export SCOUT_LINEAR_TEST_TEAM=$TEAM
demo() {
  feed | perl -e 'alarm shift; exec @ARGV' 120 "$APP" --linear-demo="$SESSION" --linear-demo-key-stdin \
    --linear-demo-session="$RUN" --linear-demo-title-prefix="[scout-test] " --linear-demo-video="$VIDEO" \
    --linear-demo-output="$OUT" --linear-demo-label="$1" --linear-demo-send="$2" > "$OUT/$1.stdout" 2>&1
}
echo "== Scout filing flow ($RUN)"
demo live-1-file first
demo live-2-resend first
rm -f "$SESSION/review.json"
demo live-3-no-review-json first
python3 -I - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
for label in ["live-1-file", "live-2-resend", "live-3-no-review-json"]:
    path = os.path.join(out, label + ".json")
    if not os.path.exists(path):
        print(label, "no log")
        continue
    steps = json.load(open(path))
    task = ((steps[-1].get("tasks") or [{}])[0]) if steps else {}
    print(label, task.get("identifier") or "-", task.get("issueID") or "-", task.get("state", steps[-1] if steps else ""))
PY
