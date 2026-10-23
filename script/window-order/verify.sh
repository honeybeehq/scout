#!/bin/zsh
set -u
S=${0:A:h}
R=${S:h:h}
OUT=${1:A}
SRC=${${2:-$HOME/Applications/Scout.app}:A}
KINDS=(${=3:-settings review onboarding})
V="$R/build/window-order"
mkdir -p "$V/Cover.app/Contents/MacOS" "$V/ScoutRunner.app/Contents/MacOS" "$V/mc"
plist() { printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>%s</string><key>CFBundleIdentifier</key><string>local.scout-window-order.%s</string><key>CFBundlePackageType</key><string>APPL</string>%s</dict></plist>\n' "$1" "$1" "$2" > "$3"; }
if [[ ! -x "$V/wincheck" ]]; then
  swiftc -O -module-cache-path "$V/mc" "$S/Cover.swift" -o "$V/Cover.app/Contents/MacOS/Cover" || exit 1
  swiftc -O -module-cache-path "$V/mc" "$S/Runner.swift" -o "$V/ScoutRunner.app/Contents/MacOS/ScoutRunner" || exit 1
  swiftc -O -module-cache-path "$V/mc" "$S/wincheck.swift" -o "$V/wincheck" || exit 1
  plist Cover "" "$V/Cover.app/Contents/Info.plist"
  plist ScoutRunner "<key>LSUIElement</key><true/>" "$V/ScoutRunner.app/Contents/Info.plist"
  codesign -s - --force "$V/Cover.app" "$V/ScoutRunner.app"
fi
rm -rf "$OUT"; mkdir -p "$OUT"

open "$V/Cover.app"; sleep 2
COVER_PID=$(pgrep -f "$V/Cover.app/Contents/MacOS/Cover" | head -1)
printf '%s\n' "$SRC/Contents/MacOS/Scout" -onboarding.complete YES "--simulate-open-settings=$OUT" > "$V/runner-args"
open -n "$V/ScoutRunner.app"
sleep 5
SCOUT_PID=$(pgrep -f "$SRC/Contents/MacOS/Scout" | head -1)
echo "cover=$COVER_PID scout=$SCOUT_PID" > "$OUT/pids.txt"

shot() { screencapture -x "$OUT/$1.png" 2>/dev/null; "$V/wincheck" > "$OUT/$1.json"; }
cover() { open "$V/Cover.app"; sleep 1.5; }
n=0
open_case() { n=$((n+1)); echo "$n $1 $2" >> "$OUT/steps.txt"; cover; shot "$n-before"; "$V/wincheck" post "$1"; sleep 2.5; shot "$n-after"; }

for k in $KINDS; do
  open_case $k first-open
  open_case $k behind-other-app
  "$V/wincheck" post "minimize-$k"; sleep 1.5
  open_case $k minimized
  cover; shot "$k-other-app-clicked"
done

[[ -n "$SCOUT_PID" ]] && kill "$SCOUT_PID"
[[ -n "$COVER_PID" ]] && kill "$COVER_PID"

python3 -I - "$OUT" $KINDS <<'PY'
import json, sys, os
out = sys.argv[1]
def load(n):
    p = os.path.join(out, n)
    return json.load(open(p)) if os.path.exists(p) else {}
ok_all = True
for line in open(os.path.join(out, "steps.txt")):
    n, kind, case = line.split()
    before, after, s = load(f"{n}-before.json"), load(f"{n}-after.json"), load(f"open-{n}.json")
    top = (after.get("windowsFrontToBack") or [{}])[0]
    ok = (before.get("frontmostApp") == "Cover" and after.get("frontmostApp") == "Scout" and top.get("owner") == "Scout"
          and top.get("id") == s.get("windowNumber") and s.get("windowKey") is True and s.get("appActive") is True
          and s.get("windowMiniaturized") is False and s.get("windowLevel") == 0)
    ok_all &= ok
    print(f"{'PASS' if ok else 'FAIL'} {kind:10} {case:16} before: front={before.get('frontmostApp')} | after: front={after.get('frontmostApp')} "
          f"top={top.get('owner')}#{top.get('id')} {kind}#{s.get('windowNumber')} key={s.get('windowKey')} active={s.get('appActive')} "
          f"minimized={s.get('windowMiniaturized')} level={s.get('windowLevel')} policy={s.get('activationPolicy')}")
for kind in sys.argv[2:]:
    last = load(f"{kind}-other-app-clicked.json")
    top = (last.get("windowsFrontToBack") or [{}])[0]
    ok = last.get("frontmostApp") == "Cover" and top.get("owner") == "Cover"
    ok_all &= ok
    print(f"{'PASS' if ok else 'FAIL'} {kind:10} {'not-floating':16} other app brought front -> front={last.get('frontmostApp')} top={top.get('owner')}")
print("RESULT", "GREEN" if ok_all else "RED")
PY
