#!/bin/bash
set -uo pipefail
if [ $# -ne 1 ]; then echo "usage: SCOUT_APP=<Scout binary built as com.trmdy.scout.dev.linear> SCOUT_DEMO_VIDEO=<mp4> run.sh <test-team-id>   (key in SCOUT_LINEAR_KEY or on stdin)" >&2; exit 2; fi
TEAM=$1
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${SCOUT_LIVE_OUT:-$PWD/linear-live-out}
APP=${SCOUT_APP:?set SCOUT_APP to the Debug Scout.app/Contents/MacOS/Scout}
VIDEO=${SCOUT_DEMO_VIDEO:?set SCOUT_DEMO_VIDEO to any short mp4}
INPUT=${SCOUT_LINEAR_KEY:-}
unset SCOUT_LINEAR_KEY
if [ -z "$INPUT" ]; then INPUT=$(cat); fi
if [[ "$INPUT" == *key=* ]]; then
  KEY=${INPUT#*key=}
  KEY=${KEY%%[[:space:]|│]*}
else
  KEY=$(printf '%s\n' "$INPUT" | while IFS= read -r line; do line=${line//[[:space:]]/}; if [ -n "$line" ]; then printf '%s' "$line"; break; fi; done)
fi
unset INPUT
if [ -z "$KEY" ]; then echo "no key" >&2; exit 2; fi
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(dirname "$APP")/../Info.plist" 2>/dev/null || true)
case "$BUNDLE" in com.trmdy.scout.dev.*) ;; *) echo "SCOUT_APP must be built with PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.linear, found '$BUNDLE'" >&2; exit 2 ;; esac
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
  if [ "${FLOW:-4}" -ne 0 ]; then exit 4; fi
}
trap finish EXIT

defaults delete "$BUNDLE.linear-demo" >/dev/null 2>&1 || true
echo "== API checks"
feed | python3 -I "$HERE/live.py" check "$TEAM" "$OUT" || echo "API checks stopped early (see api.log)"

export SCOUT_LINEAR_TEST_TEAM=$TEAM
demo() {
  feed | perl -e 'alarm shift; exec @ARGV' 120 "$APP" --linear-demo="$SESSION" --linear-demo-key-stdin \
    --linear-demo-session="$RUN" --linear-demo-title-prefix="[scout-test] " --live-delivery --linear-demo-video="$VIDEO" \
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
ids = set()
failed = False
for label in ["live-1-file", "live-2-resend", "live-3-no-review-json"]:
    path = os.path.join(out, label + ".json")
    steps = json.load(open(path)) if os.path.exists(path) else []
    task = ((steps[-1].get("tasks") or [{}])[0]) if steps else {}
    identifier, issue_id = task.get("identifier"), task.get("issueID")
    print(label, identifier or "-", issue_id or "-", task.get("state", steps[-1] if steps else "no log"))
    if not identifier:
        failed = True
    ids.add(issue_id)
if failed or len(ids) != 1:
    print("SCOUT FLOW FAILED: every run must file or adopt one and the same issue")
    sys.exit(4)
print("Scout flow: one issue across file, resend and resend without review.json")
PY
FLOW=$?
