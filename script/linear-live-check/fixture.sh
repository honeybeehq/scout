#!/bin/bash
set -u
APP=${SCOUT_APP:?set SCOUT_APP to a Scout binary built as com.trmdy.scout.dev.linear}
VIDEO=${SCOUT_DEMO_VIDEO:?set SCOUT_DEMO_VIDEO to any short mp4}
T3=${SCOUT_FIXTURE_OUT:-$PWD/linear-fixture-out}
FIXTURES=$(cd "$(dirname "$0")/../.." && pwd)/Fixtures/linear
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(dirname "$APP")/../Info.plist" 2>/dev/null || true)
export SCOUT_LINEAR_TEST_TEAM=9b1d6c3e-0a51-4b8e-9f6a-2c1f5e7a0099
if [ -e "$T3" ] && [ -n "$(ls -A "$T3" 2>/dev/null)" ]; then echo "$T3 is not empty; use a fresh SCOUT_FIXTURE_OUT" >&2; exit 2; fi
OUT=$T3/demo; mkdir -p "$OUT"
LOG=$OUT/demo-log.txt

scout() {
  local label=$1 send=$2; shift 2
  perl -e 'alarm shift; exec @ARGV' 90 "$APP" --linear-fixture=$FIXTURES --linear-fixture-state=$STATE \
    --linear-demo=$SESSION --linear-demo-video=$VIDEO --linear-demo-output=$OUT \
    --linear-demo-label=$label --linear-demo-send=$send "$@" > "$OUT/$label.stdout" 2>&1
}

receipts() {
  python3 - "$SESSION/review.json" <<'PY'
import json,sys
try: r=json.load(open(sys.argv[1]))
except Exception as e: print("  review.json:", "missing"); sys.exit()
for t in r["tasks"]:
    print("  ", t["id"], "sentTo=%s"%t.get("sentTo"), "receipt=%s"%json.dumps(t.get("linearReceipt",{}).get("status")), "generation=%s"%t.get("linearGeneration"))
PY
}

issues() {
  python3 - "$STATE/issues" <<'PY'
import json,sys,os
d=sys.argv[1]
files=sorted(os.listdir(d)) if os.path.isdir(d) else []
print("  issues in the fixture workspace:", len(files))
for f in files:
    i=json.load(open(os.path.join(d,f)))
    print("   ", i["identifier"], i["id"], "trashed=%s"%i["trashed"], "labels=%s"%i["labelIds"], "priority=%s"%i["priority"], "title=%r"%i["title"])
PY
}

say() { echo "$@" | tee -a "$LOG"; }
section() { echo | tee -a "$LOG"; say "== $*"; }
show() { { receipts; issues; } | tee -a "$LOG"; }

defaults delete "$BUNDLE.linear-demo" 2>/dev/null
STATE=$T3/state-a SESSION=$T3/session-a
mkdir -p $STATE

section "A1 open the review (seeded), nothing sent"
scout a1-open none; show
section "A2 send task 1, Linear's reply held 30 s, Scout killed with SIGKILL mid-send"
SCOUT_LINEAR_FIXTURE_CREATE_DELAY=30 scout a2-kill first &
for i in $(seq 1 60); do grep -q "holding" $STATE/requests.log 2>/dev/null && break; sleep 0.5; done
sleep 1
PID=$(pgrep -f "linear-demo-label=a2-kill" | head -1); say "  killing pid $PID while issueCreate is in flight"; kill -9 $PID; wait 2>/dev/null
show
section "A3 resend task 1 after the crash"
scout a3-resend first; show
section "A4 delete review.json, reopen (reseeded), resend task 1"
rm $SESSION/review.json
scout a4-no-review-json first; show
section "A5 task 1 unsent locally (as after a crash before its receipt was saved) while its issue was trashed in Linear; resend"
python3 - $STATE/issues <<'PY'
import json,os,sys
d=sys.argv[1]
for f in os.listdir(d):
    p=os.path.join(d,f); i=json.load(open(p))
    if i["identifier"]=="TST-1": i["trashed"]=True; json.dump(i,open(p,"w"),indent=2)
PY
python3 - $SESSION/review.json <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); t=r["tasks"][0]; t.pop("sentTo",None); json.dump(r,open(p,"w"),indent=2)
PY
scout a5-remote-deleted first; show
section "A6 File as new issue"
scout a6-file-new file-new; show
section "A7 Send all"
scout a7-send-all all; show
cp $STATE/requests.log $OUT/requests-a.log

STATE=$T3/state-b SESSION=$T3/session-b
mkdir -p $STATE
defaults delete "$BUNDLE.linear-demo" 2>/dev/null
section "B1 fixture refuses client-chosen ids: send task 1"
SCOUT_LINEAR_FIXTURE_REFUSE_IDS=1 scout b1-refused first; show
section "B2 delete review.json, resend task 1 (marker search must adopt)"
rm $SESSION/review.json
SCOUT_LINEAR_FIXTURE_REFUSE_IDS=1 scout b2-marker-adopt first; show
cp $STATE/requests.log $OUT/requests-b.log

STATE=$T3/state-c SESSION=$T3/session-c
mkdir -p $STATE
defaults delete "$BUNDLE.linear-demo" 2>/dev/null
section "C1 --dry-run-delivery"
scout c1-dry-run first --dry-run-delivery; show
cp $SESSION/snippets/task-0/issue.md $OUT/issue.md 2>/dev/null && say "  wrote issue.md"; ls $SESSION/snippets/task-0 | tee -a $LOG
section "requests (state-a)"; cat $OUT/requests-a.log | tee -a $LOG
section "requests (state-b)"; cat $OUT/requests-b.log | tee -a $LOG
section "what reached the fixture workspace or issue.md: no URL query token, no API key"
grep -rl "SCOUTFIXTURENOTAREALKEY\|tok_demo_should_not_leave" $T3/state-a $T3/state-b $T3/state-c $OUT/issue.md 2>/dev/null | tee -a $LOG; say "  (no files listed above = clean)"
say "  the query token is still in the local review.json (Scout's own record on this Mac):"; grep -c "tok_demo_should_not_leave" $T3/session-a/review.json | tee -a $LOG
section "the API key never reaches local files"; grep -rl "SCOUTFIXTURENOTAREALKEY" $T3/session-* | tee -a $LOG; say "  (no files listed above = clean)"
section "home path check"; grep -rl "$HOME" $T3/state-a/issues $T3/state-b/issues $OUT/issue.md | tee -a $LOG; say "  (no files listed above = clean)"
