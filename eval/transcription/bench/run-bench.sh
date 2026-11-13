#!/bin/zsh
# usage: bench/run-bench.sh <outdir> [repeats] [variants]
set -euo pipefail
here="${0:A:h}"
out="$1"; repeats="${2:-1}"; variants="${3:-c,b,a}"
mkdir -p "$out"
for i in $(seq 1 "$repeats"); do
  for v in ${(s:,:)variants}; do
    echo "== bench variant $v run $i"
    "$here/../run_variant.sh" "$v" "$here/bench-samantha.wav" "$out/bench.$v.run$i.json" "$here/bench-context.txt" en-US
  done
done
for v in ${(s:,:)variants}; do cp "$out/bench.$v.run1.json" "$out/bench.$v.json"; done
python3 -I "$here/../score.py" --refs "$here/refs" --hyps "$out" --variants "$variants"
