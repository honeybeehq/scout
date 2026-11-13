#!/bin/zsh
# usage: run_variant.sh <variant a|b|c|d|e> <audio.wav> <out.json> [context.txt] [locale]
#   a  Apple today: progressive preset, Locale.current, no context, paced like the microphone
#   b  Apple + contextual strings + explicit locale, progressive, paced
#   c  Apple whole-recording second pass (explicit locale, contextual strings)
#   d  WhisperKit large-v3-turbo 632MB (planned ship build), whole recording, network denied
#   e  WhisperKit large-v3-turbo full precision (eval only), whole recording, network denied
#   f  Apple DictationTranscriber + contextual strings + explicit locale, progressive, paced
#   g  Apple DictationTranscriber + contextual strings, whole-recording second pass
#   f0 / g0  the same without contextual strings (baselines)
# Whisper needs SCOUT_EVAL_WHISPER_PINS pointing at the verified pins folder (never committed).
set -euo pipefail
here="${0:A:h}"
variant="$1"; audio="$2"; out="$3"; context="${4:-}"; locale="${5:-en-US}"
pins="${SCOUT_EVAL_WHISPER_PINS:-}"
models="$pins/whisperkit-coreml@0f63a780"
tokenizer="$pins/whisper-large-v3-turbo@41f01f3f"
apple="$here/.build/release/scout-transcribe-eval"
whisper="$here/whisper/.build/release/scout-whisper-eval"
no_network=(sandbox-exec -p '(version 1)(allow default)(deny network*)')
case "$variant" in
  a) cmd=("$apple" --audio "$audio" --out "$out" --preset progressive --locale current --paced) ;;
  b) cmd=("$apple" --audio "$audio" --out "$out" --preset progressive --locale "$locale" --paced); [[ -n "$context" ]] && cmd+=(--context "$context") ;;
  c) cmd=("$apple" --audio "$audio" --out "$out" --preset whole --locale "$locale"); [[ -n "$context" ]] && cmd+=(--context "$context") ;;
  d) cmd=("${no_network[@]}" "$whisper" --audio "$audio" --out "$out" --label whisper-turbo-632MB --language "${locale%%-*}" --model-folder "$models/openai_whisper-large-v3-v20240930_turbo_632MB" --tokenizer-folder "$tokenizer") ;;
  e) cmd=("${no_network[@]}" "$whisper" --audio "$audio" --out "$out" --label whisper-turbo-full --language "${locale%%-*}" --model-folder "$models/openai_whisper-large-v3-v20240930_turbo" --tokenizer-folder "$tokenizer") ;;
  f) cmd=("$apple" --audio "$audio" --out "$out" --module dictation --preset progressive --locale "$locale" --paced); [[ -n "$context" ]] && cmd+=(--context "$context") ;;
  g) cmd=("$apple" --audio "$audio" --out "$out" --module dictation --preset whole --locale "$locale"); [[ -n "$context" ]] && cmd+=(--context "$context") ;;
  f0) cmd=("$apple" --audio "$audio" --out "$out" --module dictation --preset progressive --locale "$locale" --paced) ;;
  g0) cmd=("$apple" --audio "$audio" --out "$out" --module dictation --preset whole --locale "$locale") ;;
  *) echo "variant must be a, b, c, d, e, f, g, f0 or g0"; exit 2 ;;
esac
if [[ "$variant" == [de] && -z "$pins" ]]; then echo "set SCOUT_EVAL_WHISPER_PINS"; exit 2; fi
[[ -n "${SCOUT_EVAL_INSTALL_ASSETS:-}" && "$variant" != [de] ]] && cmd+=(--install-assets)
samples="$out.mem"
: > "$samples"
( while true; do ps -axo rss,comm | awk '/localspeechrecognition/ && !/awk/ {s+=$1} END {print s+0}' >> "$samples"; sleep 0.25; done ) &
sampler=$!
trap 'kill $sampler 2>/dev/null' EXIT
sleep 0.5
baseline=$(head -1 "$samples")
if [[ "$variant" == [de] ]]; then
  if ! "${cmd[@]}" 2> "$out.err"; then
    cat "$out.err" >&2
    if grep -q "sandbox_apply" "$out.err" && [[ "${SCOUT_EVAL_ALLOW_UNSANDBOXED:-0}" == 1 ]]; then
      echo "  sandbox-exec refused; running UNSANDBOXED because SCOUT_EVAL_ALLOW_UNSANDBOXED=1" >&2
      "${cmd[@]:3}"
      python3 -I - "$out" <<'PY'
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d["metrics"]["networkDenied"] = False
with open(sys.argv[1], "w") as f: json.dump(d, f, indent=2, sort_keys=True)
PY
    elif grep -q "sandbox_apply" "$out.err"; then
      echo "  sandbox-exec refused to run the whisper process here; variant $variant FAILED (rerun with --allow-unsandboxed only after Needle approves)" >&2
      rm -f "$out.err"; exit 4
    else
      rm -f "$out.err"; exit 1
    fi
  fi
  rm -f "$out.err"
else
  "${cmd[@]}"
fi
kill $sampler 2>/dev/null; trap - EXIT
peak=$(sort -n "$samples" | tail -1)
python3 -I - "$out" "${baseline:-0}" "${peak:-0}" <<'PY'
import json, sys
path, baseline, peak = sys.argv[1], int(sys.argv[2] or 0), int(sys.argv[3] or 0)
with open(path) as f: d = json.load(f)
d["metrics"]["speechDaemonBaselineMB"] = round(baseline / 1024, 1)
d["metrics"]["speechDaemonPeakMB"] = round(peak / 1024, 1)
with open(path, "w") as f: json.dump(d, f, indent=2, sort_keys=True)
m = d["metrics"]
print(f"  localspeechrecognition RSS: baseline {m['speechDaemonBaselineMB']} MB, peak {m['speechDaemonPeakMB']} MB")
PY
rm -f "$samples"
