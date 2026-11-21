#!/bin/bash
set -u
APP=${SCOUT_APP:?set SCOUT_APP to a Scout binary built as com.trmdy.scout.dev.linear}
ROOT=${SCOUT_FIXTURE_OUT:-$PWD/linear-fixture-parent-out}
FIXTURES=$(cd "$(dirname "$0")/../.." && pwd)/Fixtures/linear
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(dirname "$APP")/../Info.plist" 2>/dev/null || true)
case "$BUNDLE" in com.trmdy.scout.dev.*) ;; *) echo "SCOUT_APP must be built with PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.linear, found '$BUNDLE'" >&2; exit 2 ;; esac
TST=9b1d6c3e-0a51-4b8e-9f6a-2c1f5e7a0099
WEB=9b1d6c3e-0a51-4b8e-9f6a-2c1f5e7a0002
export SCOUT_LINEAR_TEST_TEAM=$TST,$WEB
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
summary() {
  python3 - "$OUT/$1.json" <<'PY' | tee -a "$LOG"
import json,sys
for step in json.load(open(sys.argv[1])):
    if "tasks" not in step:
        print("  ", json.dumps(step)); continue
    print("  [%s] segmentation=%s structure=%s chosenInReview=%s parent=%s parentTitle=%r" % (step["step"], step["segmentation"], step["structure"], step["structureChosenInReview"], step["parent"], step["parentTitle"]))
    print("     planned children=%s standalone=%s caution=%r" % (step["plannedChildren"], step["standalone"], step["caution"]))
    for t in step["tasks"]:
        print("     %s dest=%s state=%s subIssueOf=%s" % (t["task"], t["destination"], t["state"], t["subIssueOf"]))
PY
}
workspace() {
  say "-- fixture workspace ($1)"
  python3 - "$STATE/issues" <<'PY' | tee -a "$LOG" | tee "$OUT/workspace-$1.txt"
import json,sys,os
d=sys.argv[1]
issues=[json.load(open(os.path.join(d,f))) for f in sorted(os.listdir(d))] if os.path.isdir(d) else []
issues.sort(key=lambda i: int(i["identifier"].split("-")[1]))
print("  issues:", len(issues))
for i in issues:
    p=i.get("parent")
    print("   %-6s team=%s parent=%-6s updates=%s title=%r" % (i["identifier"], i["teamId"][-4:], p["identifier"] if p else "-", i.get("updatedCount",0), i["title"]))
for i in issues:
    if "parent" not in i and any((j.get("parent") or {}).get("id")==i["id"] for j in issues):
        print("\n  parent description of %s:\n" % i["identifier"] + "\n".join("    | "+l for l in i["description"].split("\n")))
PY
}
requests() { say "-- requests.log ($1)"; cat $STATE/requests.log | tee -a "$LOG"; cp $STATE/requests.log $OUT/requests-$1.log; }
creates() { say "-- issueCreate calls so far: $(grep -c 'issueCreate(' $STATE/requests.log) · created: $(grep -c ' created ' $STATE/requests.log) · issueUpdate: $(grep -c 'issueUpdate(' $STATE/requests.log)"; }

section "A1 automatic session, Settings defaults: one issue per task"
fresh a1; scout a1-auto-default none; summary a1-auto-default
section "A2 automatic session, parent chosen in the review (stored per recording)"
fresh a2; scout a2-auto-parent none --linear-demo-structure=parent; summary a2-auto-parent
say "-- review.json linearStructure: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("linearStructure"))' $SESSION/review.json)"
section "M1 manual session, Settings defaults: parent + sub-issues, with the parent-title popover"
fresh m1; scout m1-manual-default none --linear-demo-manual --linear-demo-popover; summary m1-manual-default
section "M2 manual session, one issue per task chosen in the review"
fresh m2; scout m2-manual-pertask none --linear-demo-manual --linear-demo-structure=perTask; summary m2-manual-pertask

section "P1 manual session: File all in Linear → parent first, then children in task order"
fresh p1; scout p1-send-all all --linear-demo-manual; summary p1-send-all; requests p1; workspace p1; creates
section "P2 send all again with review.json intact (nothing waiting)"
scout p2-resend all --linear-demo-manual; summary p2-resend; creates
section "P3 delete review.json, then send all again: adopt by derived id, no new parent or children"
rm $SESSION/review.json
scout p3-resend-no-review-json all --linear-demo-manual; summary p3-resend-no-review-json; requests p3; workspace p3; creates

section "X1 manual session with the last task routed to WEB: caution, then send all"
fresh x1; scout x1-cross-team all --linear-demo-manual --linear-demo-other-team=WEB --linear-demo-popover; summary x1-cross-team; requests x1; workspace x1; creates

section "C1 marker mode (workspace refuses client ids): Send all pressed twice at once → still one parent"
fresh c1; SCOUT_LINEAR_FIXTURE_REFUSE_IDS=1 scout c1-send-all-twice all-twice --linear-demo-manual; summary c1-send-all-twice; requests c1; workspace c1; creates
