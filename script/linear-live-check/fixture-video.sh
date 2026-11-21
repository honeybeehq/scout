#!/bin/bash
set -u
APP=${SCOUT_APP:?set SCOUT_APP to a Scout binary built as com.trmdy.scout.dev.linear}
ROOT=${SCOUT_FIXTURE_OUT:-$PWD/linear-fixture-video-out}
FIXTURES=$(cd "$(dirname "$0")/../.." && pwd)/Fixtures/linear
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(dirname "$APP")/../Info.plist" 2>/dev/null || true)
case "$BUNDLE" in com.trmdy.scout.dev.*) ;; *) echo "SCOUT_APP must be built with PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.linear, found '$BUNDLE'" >&2; exit 2 ;; esac
export SCOUT_LINEAR_TEST_TEAM=9b1d6c3e-0a51-4b8e-9f6a-2c1f5e7a0099
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then echo "$ROOT is not empty; use a fresh SCOUT_FIXTURE_OUT" >&2; exit 2; fi
OUT=$ROOT/demo; mkdir -p "$OUT"
LOG=$OUT/demo-log.txt
VIDEO=${SCOUT_T4_VIDEO:-$ROOT/demo-screen.mp4}

[ -f "$VIDEO" ] || perl -e 'alarm shift; exec @ARGV' 300 "$APP" --linear-demo=$ROOT/unused --linear-demo-make-video=$VIDEO --linear-demo-output=$OUT --linear-demo-label=make-video

scout() {
  local label=$1 send=$2; shift 2
  perl -e 'alarm shift; exec @ARGV' 180 "$APP" --linear-fixture=$FIXTURES --linear-fixture-state=$STATE \
    --linear-demo=$SESSION --linear-demo-video=$VIDEO --linear-demo-output=$OUT \
    --linear-demo-label=$label --linear-demo-send=$send --live-delivery "$@" > "$OUT/$label.stdout" 2>&1
}

say() { echo "$@" | tee -a "$LOG"; }
section() { echo | tee -a "$LOG"; say "== $*"; }
fresh() { STATE=$ROOT/state-$1 SESSION=$ROOT/session-$1; rm -rf $STATE $SESSION; mkdir -p $STATE; defaults delete "$BUNDLE.linear-demo" 2>/dev/null; }
requests() { say "-- requests.log ($1)"; cat $STATE/requests.log | tee -a "$LOG"; cp $STATE/requests.log $OUT/requests-$1.log; }
summary() {
  python3 - "$OUT/$1.json" <<'PY' | tee -a "$LOG"
import json,sys
for step in json.load(open(sys.argv[1])):
    if "tasks" in step:
        t = step["tasks"][0]
        print("  [%s] task-0 state=%s includeVideo=%s redaction=%s receipt=%s clipAttachment=%s unlinkedClip=%s" % (step["step"], t["state"], t["includeVideo"], t["redaction"], t["receipt"], t["clipAttachment"], t.get("unlinkedClip")))
        for a in t["uploadedAssets"]: print("     uploaded:", a)
    else:
        print("  ", json.dumps(step))
PY
}
issues() {
  python3 - "$STATE/issues" <<'PY' | tee -a "$LOG"
import json,sys,os
d=sys.argv[1]
files=sorted(os.listdir(d)) if os.path.isdir(d) else []
print("  issues in the fixture workspace:", len(files))
for f in files:
    i=json.load(open(os.path.join(d,f)))
    clip=[l for l in i["description"].split("\n") if "clip.mp4" in l or "Video not included" in l]
    print("   ", i["identifier"], "attachments=%s" % [(a["title"], a["url"].split("/")[-1]) for a in i.get("attachments", [])], "clip line=%r" % clip)
PY
}

section "V1 Settings default (include video: off). Open, then file task 1"
fresh v1
scout v1-default-off first; summary v1-default-off; issues; requests v1
say "-- video fileUploads with the toggle off (expect none):"; grep -c "video/mp4" $STATE/requests.log | tee -a "$LOG"

section "V2 include video on, no edits: the passthrough clip uploads, with progress, then the clip card"
fresh v2
SCOUT_LINEAR_FIXTURE_UPLOAD_SECONDS=8 scout v2-video-on first --linear-demo-include-video --linear-demo-midshot=4.5; summary v2-video-on; issues; requests v2
ls -l $SESSION/snippets/task-0/ | tee -a "$LOG"

section "V3 include video on with a redaction: two hidden areas and one cut part"
fresh v3
scout v3-redacted first --linear-demo-include-video --linear-demo-redact --linear-demo-sheet=preview; summary v3-redacted; issues
cp $SESSION/snippets/task-0/pin-1.png $OUT/v3-uploaded-pin-1.png 2>/dev/null
ls -l $SESSION/snippets/task-0/ $STATE/uploads | tee -a "$LOG"
say "-- the uploaded video is byte-identical to the redacted render, not the original clip:"
for f in $STATE/uploads/*; do s=$(shasum -a 256 "$f" | cut -c1-16); say "   upload $(basename $f) $(stat -f %z "$f") bytes sha=$s"; done
for f in $SESSION/snippets/task-0/clip.mp4 $SESSION/snippets/task-0/clip-redacted-*.mp4; do s=$(shasum -a 256 "$f" | cut -c1-16); say "   local  $(basename $f) $(stat -f %z "$f") bytes sha=$s"; done
section "V3b resend: adopts the issue, no second upload, no second clip card"
scout v3b-resend first --linear-demo-include-video --linear-demo-redact; summary v3b-resend; issues; requests v3

section "V3c crash after the issue was created but before the clip card: review.json loses sentTo and the attachment id"
python3 - $SESSION/review.json <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); t=r["tasks"][0]; t.pop("sentTo",None); t["linearReceipt"].pop("clipAttachmentID",None); json.dump(r,open(p,"w"),indent=2)
PY
: > $STATE/requests.log
scout v3c-crash-before-attach first --linear-demo-include-video --linear-demo-redact; summary v3c-crash-before-attach; issues; requests v3c

section "V5 video on, Scout killed while issueCreate is in flight (the clip was already uploaded)"
fresh v5
SCOUT_LINEAR_FIXTURE_CREATE_DELAY=30 scout v5-kill first --linear-demo-include-video &
for i in $(seq 1 120); do grep -q "holding" $STATE/requests.log 2>/dev/null && break; sleep 0.5; done
sleep 1
PID=$(pgrep -f "linear-demo-label=v5-kill" | head -1); say "  killing pid $PID while issueCreate is in flight"; kill -9 $PID; wait 2>/dev/null
python3 - $SESSION/review.json <<'PY' | tee -a "$LOG"
import json,sys
r=json.load(open(sys.argv[1])); t=r["tasks"][0]
print("  receipt after the kill:", json.dumps(t.get("linearReceipt",{}).get("status")), "assets:", [a["name"] for a in t.get("linearReceipt",{}).get("assets",[])])
PY
section "V5b the user turns video off, then resends: the issue is adopted, the clip is not attached, and the clip link is replaced with Video not included"
python3 - $SESSION/review.json <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); t=r["tasks"][0]; t.setdefault("linear",{})["includeVideo"]=False; json.dump(r,open(p,"w"),indent=2)
PY
: > $STATE/requests.log
scout v5b-video-off-resend first; summary v5b-video-off-resend; issues; requests v5b

section "V6 video on and filed with its clip card; review.json then loses the sent state and the user turns video off; resend"
fresh v6
scout v6-filed first --linear-demo-include-video; summary v6-filed; issues
python3 - $SESSION/review.json <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); t=r["tasks"][0]; t.pop("sentTo",None); t["linearReceipt"]["status"]={"pending":{}}; t.setdefault("linear",{})["includeVideo"]=False; json.dump(r,open(p,"w"),indent=2)
PY
: > $STATE/requests.log
scout v6b-video-off-unlinks first; summary v6b-video-off-unlinks; issues; requests v6b

section "V4 too big for Linear (fixture video limit 1000 bytes): the error offers File without video"
fresh v4
SCOUT_LINEAR_FIXTURE_MAX_VIDEO=1000 scout v4-too-large first --linear-demo-include-video; summary v4-too-large
section "V4b File without video"
SCOUT_LINEAR_FIXTURE_MAX_VIDEO=1000 scout v4b-without-video without-video; summary v4b-without-video; issues; requests v4

section "C1 --dry-run-delivery with video and the redaction: issue.md, nothing leaves the Mac"
fresh c1
scout c1-dry-run first --linear-demo-include-video --linear-demo-redact --dry-run-delivery; summary c1-dry-run
cp $SESSION/snippets/task-0/issue.md $OUT/issue.md 2>/dev/null && say "  wrote issue.md"; ls $SESSION/snippets/task-0 | tee -a "$LOG"
say "-- requests during the dry run (expect only reads):"; cat $STATE/requests.log 2>/dev/null | tee -a "$LOG"

section "secrets from the demo screen never reach the fixture workspace text"
grep -rl "sk_live\|hunter2\|tok_demo_8812" $ROOT/state-* 2>/dev/null | grep -v uploads | tee -a "$LOG"; say "  (no files listed above = clean)"
