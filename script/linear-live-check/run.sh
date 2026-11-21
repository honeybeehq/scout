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
feed | python3 -I "$HERE/live.py" check "$TEAM" "$OUT" "${SCOUT_LIVE_CLIP:-}" || echo "API checks stopped early (see api.log)"

export SCOUT_LINEAR_TEST_TEAM=$TEAM
DUPE_PREFIX="[scout-test] dupe$(LC_ALL=C tr -dc 'a-z' </dev/urandom | head -c 8) "
ddemo() {
  local label=$1 send=$2; shift 2
  feed | perl -e 'alarm shift; exec @ARGV' 300 "$APP" --linear-demo="$OUT/session-dupe" --linear-demo-key-stdin \
    --linear-demo-session="$RUN-dupe" --linear-demo-title-prefix="$DUPE_PREFIX" --live-delivery --linear-demo-video="$VIDEO" \
    --linear-demo-output="$OUT" --linear-demo-label="$label" --linear-demo-send="$send" "$@" > "$OUT/$label.stdout" 2>&1
}
echo "== Scout dedupe flow, part 1: open the task and seed a similar open issue now, so Linear's search has the whole run to index it"
ddemo live-9-dupe-open none
SEED_TITLE=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print([x for x in s if "tasks" in x][0]["tasks"][0]["title"])' "$OUT/live-9-dupe-open.json" 2>/dev/null)
SEEDED=
if [ -n "$SEED_TITLE" ]; then SEEDED=$(feed | python3 -I "$HERE/live.py" dupe-seed "$TEAM" "$OUT" "$SEED_TITLE" | tail -1); fi
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

echo "== Scout video flow ($RUN): video off, then a redacted clip, then a resend"
T4VIDEO=${SCOUT_T4_VIDEO:-}
if [ -z "$T4VIDEO" ]; then
  MADE=$(mktemp -d)
  T4VIDEO=$MADE/demo-screen.mp4
  perl -e 'alarm shift; exec @ARGV' 300 "$APP" --linear-demo="$MADE/unused" --linear-demo-make-video="$T4VIDEO" --linear-demo-output="$MADE" --linear-demo-label=make-video > /dev/null 2>&1
fi
vdemo() {
  local session=$1 run=$2 label=$3 send=$4; shift 4
  feed | perl -e 'alarm shift; exec @ARGV' 300 "$APP" --linear-demo="$session" --linear-demo-key-stdin \
    --linear-demo-session="$run" --linear-demo-title-prefix="[scout-test] " --live-delivery --linear-demo-video="$T4VIDEO" \
    --linear-demo-output="$OUT" --linear-demo-label="$label" --linear-demo-send="$send" "$@" > "$OUT/$label.stdout" 2>&1
}
vdemo "$OUT/session-video-off" "$RUN-off" live-video-off first
vdemo "$OUT/session-video" "$RUN-video" live-video-redacted first --linear-demo-include-video --linear-demo-redact
vdemo "$OUT/session-video" "$RUN-video" live-video-resend first --linear-demo-include-video --linear-demo-redact
python3 -I - "$OUT/session-video/review.json" <<'PY'
import json, sys
p = sys.argv[1]; r = json.load(open(p)); t = r["tasks"][0]
t.pop("sentTo", None); t["linearReceipt"]["status"] = {"pending": {}}; t.setdefault("linear", {})["includeVideo"] = False
json.dump(r, open(p, "w"), indent=2)
PY
vdemo "$OUT/session-video" "$RUN-video" live-video-unlinked first
feed | python3 -I "$HERE/live.py" video-verify "$TEAM" "$OUT"
VVERIFY=$?
python3 -I - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
def task(label):
    path = os.path.join(out, label + ".json")
    steps = json.load(open(path)) if os.path.exists(path) else []
    return ((steps[-1].get("tasks") or [{}])[0]) if steps else {}
off, red, again, unlinked = task("live-video-off"), task("live-video-redacted"), task("live-video-resend"), task("live-video-unlinked")
videos = lambda t: [a for a in t.get("uploadedAssets") or [] if " video " in a]
problems = []
if not off.get("identifier") or videos(off) or off.get("includeVideo"): problems.append("video off: expected an issue and no video asset")
if not red.get("identifier") or len(videos(red)) != 1 or red.get("clipAttachment") in (None, "none"): problems.append("redacted: expected one video asset and a clip attachment")
if again.get("issueID") != red.get("issueID") or again.get("clipAttachment") != red.get("clipAttachment") or videos(again) != videos(red): problems.append("resend: expected the same issue, video and attachment")
if unlinked.get("issueID") != red.get("issueID") or videos(unlinked) or unlinked.get("clipAttachment") not in (None, "none") or not unlinked.get("unlinkedClip"): problems.append("video turned off after filing: expected the same issue with the clip unlinked")
print("\n".join(problems) if problems else "Scout video flow: off files no video; redacted uploads one clip and one card; resend changes nothing; video turned off afterwards unlinks the clip")
sys.exit(5 if problems else 0)
PY
VFLOW=$?
if [ "$VFLOW" -eq 0 ] && [ "$VVERIFY" -ne 0 ]; then VFLOW=$VVERIFY; fi
[ -n "${MADE:-}" ] && rm -rf "$MADE"
if [ "$FLOW" -eq 0 ] && [ "$VFLOW" -ne 0 ]; then FLOW=$VFLOW; fi

echo "== Scout parent flow ($RUN): a manual session filed as a parent with sub-issues, then two resends"
pdemo() {
  feed | perl -e 'alarm shift; exec @ARGV' 180 "$APP" --linear-demo="$OUT/session-parent" --linear-demo-key-stdin \
    --linear-demo-session="$RUN-parent" --linear-demo-title-prefix="[scout-test] " --live-delivery --linear-demo-video="$VIDEO" \
    --linear-demo-output="$OUT" --linear-demo-label="$1" --linear-demo-send=all --linear-demo-manual > "$OUT/$1.stdout" 2>&1
}
pdemo live-6-parent
pdemo live-7-parent-resend
rm -f "$OUT/session-parent/review.json"
pdemo live-8-parent-no-review-json
feed | python3 -I "$HERE/live.py" parent-verify "$TEAM" "$OUT"
PFLOW=$?
if [ "$FLOW" -eq 0 ] && [ "$PFLOW" -ne 0 ]; then FLOW=$PFLOW; fi

echo "== Scout dedupe flow, part 2: wait for search, Add to it with video on, then two resends"
DFLOW=7
if [ -n "$SEEDED" ]; then
  read -r SEED_ID SEED_IDENTIFIER SEED_URL < <(feed | python3 -I "$HERE/live.py" dupe-wait "$TEAM" "$OUT" "$SEED_TITLE" | tail -1)
  CHOOSE=(--linear-demo-add-to="$SEED_ID" --linear-demo-add-to-identifier="$SEED_IDENTIFIER" --linear-demo-add-to-url="$SEED_URL" --linear-demo-include-video)
  ddemo live-10-dupe-add first "${CHOOSE[@]}" --linear-demo-menubar
  ADDED=$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print([x for x in s if "tasks" in x][-1]["tasks"][0]["addedToIssueID"])' "$OUT/live-10-dupe-add.json" 2>/dev/null)
  if [ "$ADDED" = "$SEED_ID" ]; then
    ddemo live-11-dupe-resend first --linear-demo-menubar
    rm -f "$OUT/session-dupe/review.json"
    ddemo live-12-dupe-no-review-json first "${CHOOSE[@]}"
  else
    echo "live-10 did not add to $SEED_IDENTIFIER, so the resends are skipped (they would have no add-to choice)"
  fi
  feed | python3 -I "$HERE/live.py" dupe-verify "$TEAM" "$OUT"
  DFLOW=$?
else
  echo "no seeded issue (title=${SEED_TITLE:-none})"
fi
if [ "$FLOW" -eq 0 ] && [ "$DFLOW" -ne 0 ]; then FLOW=$DFLOW; fi
