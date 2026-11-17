# Transcription eval harness

Measures Scout's transcription options on the same audio: word error rate (WER), the error rate on
tagged names and terms, speed and memory. It runs outside the app and never touches ~/Applications/Scout.app.

## Variants
| | Engine | Settings |
|---|---|---|
| a | Apple SpeechTranscriber | progressive preset, `Locale.current`, no contextual strings, audio paced like a microphone (what Scout does today) |
| b | Apple SpeechTranscriber | progressive preset, explicit locale, contextual strings (app names, window titles, screen text, user terms) |
| c | Apple SpeechTranscriber | whole-recording second pass, explicit locale, contextual strings |
| d | WhisperKit large-v3-turbo 632 MB | whole-recording second pass, word timestamps, network denied |
| e | WhisperKit large-v3-turbo full precision | eval only |
| f | Apple DictationTranscriber | progressive long dictation, explicit locale, contextual strings (SpeechTranscriber ignores them; DictationTranscriber honours them) |
| g | Apple DictationTranscriber | whole-recording long dictation, explicit locale, contextual strings |
| f0, g0 | Apple DictationTranscriber | f and g without contextual strings, as baselines |
| p | Parakeet TDT 0.6B v2 (FluidAudio, CoreML) | whole-recording second pass, word timings from token timings, network denied, eval only |

## Build
    swift build -c release
    SCOUT_EVAL_WHISPERKIT_PATH=<verified WhisperKit v1.1.1 clone> swift build -c release --package-path whisper

    parakeet/make-offline-overlay.sh <verified FluidAudio v0.18.3 clone> <dir>/FluidAudio
    SCOUT_EVAL_FLUIDAUDIO_PATH=<dir>/FluidAudio swift build -c release --package-path parakeet

The overlay is a manifest over symlinks to the clone's own sources with no binary target: SwiftPM 6.2 still tries to
download the NemoTextProcessing xcframework from the clone's manifest even with `traits: []`, which hangs with the
network denied. The compiled sources are byte-identical to the verified clone.
Without the path overrides the packages pin `argmaxinc/WhisperKit` at exactly 1.1.1 and `FluidInference/FluidAudio`
at exactly 0.18.3 with `traits: []` (no NemoTextProcessing binary, no TTS, no diarizer). `SCOUT_EVAL_PARAKEET_PINS`
points at the verified Parakeet folder (`whisper-pins.md` §7.4).
Model and tokenizer files are never downloaded by the harness: `SCOUT_EVAL_WHISPER_PINS` must point at a
folder laid out like `whisper-pins.md` §4, verified by SHA-256 first. Whisper runs under `sandbox-exec`
with `(deny network*)` so WhisperKit's tokenizer Hub fallback can never fire.

## Run
    ./run.sh <data-dir> <out-dir> [a,b,c,d,e,f,g,f0,g0,p]

`<data-dir>` (outside the repo) holds `audio/<name>.wav`, `refs/<name>.txt` and optionally
`context/<name>.txt` or `context.txt`. References are plain text with names and terms tagged like
`[WezTerm]`; `score.py` reports WER and the share of tagged terms that came out wrong, twice: in spoken form
(CamelCase, hyphens and case ignored, so "speech analyzer" counts for `SpeechAnalyzer`) and in written form
(case ignored, but `SpeechAnalyzer` must appear as one word and `scout-segment` with its hyphen).
`context_from_session.py signals.jsonl` builds a contextual-strings file from a Scout session the way
the app would. `screen_terms_check.py walkthrough.json` checks a walkthrough transcript against the
on-screen labels of its pointers when there is no audio to score.

## Benchmark clip
`bench/refs/bench.txt` is a non-private script rendered with `say -v Samantha` into
`bench/bench-samantha.wav` (not committed). `bench/run-bench.sh <out> [repeats] [variants]` runs it and
prints the score table; use the same WAV on every machine so the speed numbers compare.

## Memory
Apple's model runs in the system process `localspeechrecognition`, so the harness samples that
process's RSS during the run (`speechDaemonPeakMB`) besides its own footprint. WhisperKit runs in
process, so `peakFootprintMB` is the real cost.
