#!/bin/bash
set -euo pipefail
if [ $# -ne 1 ]; then echo "usage: <key on stdin> run.sh <test-team-id>" >&2; exit 2; fi
TEAM=$1
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${SCOUT_LIVE_OUT:-$HOME/scout-t3/live}
APP=${SCOUT_APP:-$HOME/scout-t3/DerivedData/Build/Products/Debug/Scout.app/Contents/MacOS/Scout}
mkdir -p "$OUT"
IFS= read -r KEY
printf '%s\n' "$KEY" | python3 -I "$HERE/check_api.py" "$TEAM" "$OUT/api.log"

export SCOUT_LINEAR_TEST_TEAM=$TEAM
SESSION=$OUT/session
rm -rf "$SESSION"
demo() {
  printf '%s\n' "$KEY" | perl -e 'alarm shift; exec @ARGV' 120 "$APP" --linear-demo="$SESSION" --linear-demo-key-stdin \
    --linear-demo-video="${SCOUT_DEMO_VIDEO:-$HOME/scout-t3/demo-video.mp4}" --linear-demo-output="$OUT" --linear-demo-label="$1" --linear-demo-send="$2" > "$OUT/$1.stdout" 2>&1
}
demo live-1-file first
demo live-2-resend first
rm "$SESSION/review.json"
demo live-3-no-review-json first
python3 -I - "$OUT" <<'PY'
import json, sys, os
out = sys.argv[1]
for label in ["live-1-file", "live-2-resend", "live-3-no-review-json"]:
    steps = json.load(open(os.path.join(out, label + ".json")))
    last = steps[-1]
    first = (last.get("tasks") or [{}])[0]
    print(label, first.get("state"), first.get("receipt"))
PY
unset KEY
