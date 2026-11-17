#!/bin/zsh
# usage: run.sh <data-dir> <out-dir> [variants]
# data-dir holds audio/*.wav, refs/<name>.txt (tagged references) and optional context/<name>.txt or context.txt.
set -euo pipefail
here="${0:A:h}"
data="$1"; out="$2"; variants="${3:-a,b,c,f,g,f0,g0,d,e,p}"
mkdir -p "$out"
for wav in "$data"/audio/*.wav; do
  name="${wav:t:r}"
  context="$data/context/$name.txt"
  [[ -f "$context" ]] || context="$data/context.txt"
  [[ -f "$context" ]] || context=""
  for v in ${(s:,:)variants}; do
    echo "== $name variant $v"
    "$here/run_variant.sh" "$v" "$wav" "$out/$name.$v.json" "$context" "${SCOUT_EVAL_LOCALE:-en-US}"
  done
done
python3 -I "$here/score.py" --refs "$data/refs" --hyps "$out" --variants "$variants" --json "$out/scores.json"
