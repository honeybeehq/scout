#!/bin/bash
set -u
APP=${SCOUT_APP:?set SCOUT_APP to a Scout binary built as com.trmdy.scout.dev.linear}
ROOT=${SCOUT_FIXTURE_OUT:-$PWD/linear-fixture-dedupe-out}
FIXTURES=$(cd "$(dirname "$0")/../.." && pwd)/Fixtures/linear
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$(dirname "$APP")/../Info.plist" 2>/dev/null || true)
case "$BUNDLE" in com.trmdy.scout.dev.*) ;; *) echo "SCOUT_APP must be built with PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.linear, found '$BUNDLE'" >&2; exit 2 ;; esac
TST=9b1d6c3e-0a51-4b8e-9f6a-2c1f5e7a0099
export SCOUT_LINEAR_TEST_TEAM=$TST
if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then echo "$ROOT is not empty; use a fresh SCOUT_FIXTURE_OUT" >&2; exit 2; fi
OUT=$ROOT/demo; mkdir -p "$OUT"
LOG=$OUT/demo-log.txt
VIDEO=${SCOUT_T4_VIDEO:-$ROOT/demo-screen.mp4}

[ -f "$VIDEO" ] || perl -e 'alarm shift; exec @ARGV' 300 "$APP" --linear-demo=$ROOT/unused --linear-demo-make-video=$VIDEO --linear-demo-output=$OUT --linear-demo-label=make-video

scout() {
  local label=$1 send=$2; shift 2
  perl -e 'alarm shift; exec @ARGV' 240 "$APP" --linear-fixture=$FIXTURES --linear-fixture-state=$STATE \
    --linear-demo=$SESSION --linear-demo-video=$VIDEO --linear-demo-output=$OUT \
    --linear-demo-label=$label --linear-demo-send=$send --live-delivery "$@" > "$OUT/$label.stdout" 2>&1
}
say() { echo "$@" | tee -a "$LOG"; }
section() { echo | tee -a "$LOG"; say "== $*"; }
fresh() { STATE=$ROOT/state-$1 SESSION=$ROOT/session-$1; rm -rf $STATE $SESSION; mkdir -p $STATE/issues; defaults delete "$BUNDLE.linear-demo" 2>/dev/null; }
seed() {
  python3 - "$STATE" "$TST" "$@" <<'PY'
import json, os, sys, uuid
state, team, titles = sys.argv[1], sys.argv[2], sys.argv[3:]
for n, title in enumerate(titles, 1):
    i = str(uuid.uuid4())
    issue = {"id": i, "identifier": "TST-%d" % n, "url": "https://linear.app/acme/issue/tst-%d" % n, "trashed": False, "teamId": team,
             "title": title, "description": "Seeded by fixture-dedupe.sh.\n\n- **App:** Safari (`com.apple.Safari`)", "priority": 0, "labelIds": [], "state": "Backlog"}
    json.dump(issue, open(os.path.join(state, "issues", i + ".json"), "w"), indent=2)
open(os.path.join(state, "counter"), "w").write(str(len(titles)))
PY
}
summary() {
  python3 - "$OUT/$1.json" <<'PY' | tee -a "$LOG"
import json,sys
for step in json.load(open(sys.argv[1])):
    if "tasks" not in step:
        print("  ", json.dumps(step, ensure_ascii=False)); continue
    print("  [%s]" % step["step"])
    for t in step["tasks"]:
        print("     %s state=%s sentText=%r addedTo=%s comment=%s clipAttachment=%s addToChoice=%s" % (t["task"], t["state"], t["sentText"], t["addedTo"], t["commentID"] or "-", t["clipAttachment"], t["addToChoice"]))
PY
}
workspace() {
  say "-- fixture workspace ($1)"
  python3 - "$STATE/issues" <<'PY' | tee -a "$LOG"
import json,sys,os
d=sys.argv[1]
issues=[json.load(open(os.path.join(d,f))) for f in sorted(os.listdir(d))]
issues.sort(key=lambda i: int(i["identifier"].split("-")[1]))
for i in issues:
    comments=i.get("comments") or []
    print("   %-6s comments=%d attachments=%d title=%r" % (i["identifier"], len(comments), len(i.get("attachments") or []), i["title"][:70]))
    for c in comments:
        print("      comment %s footer=%r clip=%s" % (c["id"], c["body"].split("\n")[-1], "clip.mp4" in c["body"]))
PY
}
requests() { say "-- requests.log ($1)"; cat $STATE/requests.log | tee -a "$LOG"; cp $STATE/requests.log $OUT/requests-$1.log; }

section "D1 a similar open issue exists: the review shows it; Add to it; video on (redacted); add"
fresh d; seed "Pay now button looks disabled on checkout" "Cookie banner sits under the footer"
scout d1-add first --linear-demo-duplicates --linear-demo-add-to=first --linear-demo-include-video --linear-demo-redact --linear-demo-menubar
summary d1-add; workspace d1
section "D2 resend with review.json intact (the task is locked, nothing is sent)"
scout d2-resend first --linear-demo-menubar; summary d2-resend; workspace d2
section "D3 delete review.json, choose the same issue again and add: the derived comment id adopts, still one comment"
rm $SESSION/review.json
scout d3-no-review-json first --linear-demo-add-to=first --linear-demo-include-video --linear-demo-redact; summary d3-no-review-json; workspace d3
section "D4 task 2: File new (a new issue), then the menu bar shows both"
scout d4-file-new first --linear-demo-task=1 --linear-demo-duplicates --linear-demo-menubar; summary d4-file-new; workspace d4
requests d

section "M1 marker mode (workspace refuses client ids): add, delete review.json, add again: one comment"
fresh m; seed "Pay now button looks disabled on checkout"
SCOUT_LINEAR_FIXTURE_REFUSE_IDS=1 scout m1-add first --linear-demo-add-to=first; summary m1-add
rm $SESSION/review.json
SCOUT_LINEAR_FIXTURE_REFUSE_IDS=1 scout m2-add-again first --linear-demo-add-to=first; summary m2-add-again; workspace m; requests m

section "R1 Add to it chosen, nothing sent yet (the choice is saved in review.json)"
fresh r; seed "Pay now button looks disabled on checkout" "Cookie banner sits under the footer"
scout r1-choose none --linear-demo-add-to=first; summary r1-choose
say "-- review.json addTo: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0]["linear"]["addTo"]["identifier"])' $SESSION/review.json)"
section "R2 send while search returns nothing: still comments on the chosen issue, never files new"
SCOUT_LINEAR_FIXTURE_SEARCH_EMPTY=1 scout r2-send-search-empty first; summary r2-send-search-empty; workspace r2
section "R3 resend in add-to mode with search returning nothing (the task marked unsent locally): the same comment, no new issue"
python3 - $SESSION/review.json <<'PY'
import json,sys
p=sys.argv[1]; r=json.load(open(p)); t=r["tasks"][0]; t.pop("sentTo",None); t["linearReceipt"]["status"]={"pending":{}}; json.dump(r,open(p,"w"),indent=2)
PY
SCOUT_LINEAR_FIXTURE_SEARCH_EMPTY=1 scout r3-resend-search-empty first; summary r3-resend-search-empty; workspace r3
say "-- issueCreate calls in R: $(grep -c 'issueCreate(' $STATE/requests.log) · commentCreate calls: $(grep -c 'commentCreate(' $STATE/requests.log) · duplicate searches: $(grep -c 'duplicates' $STATE/requests.log)"
requests r

section "G1 the chosen issue was archived in Linear before adding: error with File as new issue / Choose another, the choice kept"
fresh g; seed "Pay now button looks disabled on checkout"
scout g1-open none --linear-demo-add-to=first
python3 - $STATE/issues <<'PY'
import json,os,sys
d=sys.argv[1]
for f in os.listdir(d):
    p=os.path.join(d,f); i=json.load(open(p)); i["archivedAt"]="2026-11-21T12:00:00Z"; json.dump(i,open(p,"w"),indent=2)
PY
scout g2-add-archived first; summary g2-add-archived; workspace g
say "-- review.json still holds the choice: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tasks"][0].get("linear",{}).get("addTo",{}).get("identifier"))' $SESSION/review.json)"
section "G3 the user presses File as new issue"
scout g3-file-new first-then-new; summary g3-file-new; workspace g3

LONG=$(python3 -c 'print("[scout-test] " + "Very long title " * 31 + "END-OF-500")')
section "H1 hostile title: markdown"
fresh h1; seed '**Bold** _italic_ `code` # Heading > quote ![img](https://evil.example/x.png)'
scout h1-markdown none --linear-demo-duplicates; summary h1-markdown
section "H2 hostile title: a link"
fresh h2; seed '[Click to fix](https://evil.example/phish) <https://evil.example> https://evil.example/raw'
scout h2-link none --linear-demo-duplicates; summary h2-link
section "H3 hostile title: 500 characters (${#LONG})"
fresh h3; seed "$LONG"
scout h3-long none --linear-demo-duplicates; summary h3-long
section "H4 all three: one inline, More (2)"
fresh h4; seed '[Click to fix](https://evil.example/phish) **now**' "$LONG" '_markdown_ `title` with a
newline and a	tab'
scout h4-all none --linear-demo-duplicates; summary h4-all

section "C1 --dry-run-delivery writes comment.md for an add"
fresh c; seed "Pay now button looks disabled on checkout"
scout c1-dry-run first --linear-demo-add-to=first --dry-run-delivery; summary c1-dry-run
cp $SESSION/snippets/task-0/comment.md $OUT/comment.md 2>/dev/null && { say "  comment.md:"; sed 's/^/    | /' $OUT/comment.md | tee -a "$LOG"; }
section "the API key and the URL query token never reach the fixture workspace"
grep -rl "SCOUTFIXTURENOTAREALKEY\|tok_demo_should_not_leave" $ROOT/state-* $OUT/comment.md 2>/dev/null | tee -a $LOG; say "  (no files listed above = clean)"
