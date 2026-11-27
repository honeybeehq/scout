## Accuracy (42 cases with a correct target; 8 no-fit cases are only used in the gate table)

| Method | Top-1 | Top-3 |
|---|---|---|
| Baseline, untuned: recency + name + raw keyword overlap | 45% (19/42) | 93% (39/42) |
| Baseline, tuned on this set: recency + name + length-normalised keywords | 76% (32/42) | 98% (41/42) |
| Jev Choice (jev-1.14.0) | 100% (42/42) | 100% (42/42) |
| Jev per-target Noul, sorted | 98% (41/42) | 100% (42/42) |

Head to head on top-1 against the tuned baseline: Jev right and baseline wrong in 10 cases, baseline right and Jev wrong in 0. Exact McNemar p = 0.0020.

## Top-1 by case type

| Tag | Cases | Baseline | Jev |
|---|---|---|---|
| context-mismatch | 2 | 100% (2/2) | 100% (2/2) |
| decoy-word | 1 | 0% (0/1) | 100% (1/1) |
| large | 2 | 100% (2/2) | 100% (2/2) |
| named | 6 | 67% (4/6) | 100% (6/6) |
| no-name | 36 | 78% (28/36) | 100% (36/36) |
| recent-wrong | 7 | 86% (6/7) | 100% (7/7) |
| similar-name | 7 | 71% (5/7) | 100% (7/7) |
| vague | 1 | 0% (0/1) | 100% (1/1) |

## Confident picks only

Coverage is the share of labelled cases where the top pick clears the bar and gets highlighted. Precision is the share of those highlights that are correct. The last column counts no-fit cases, where no candidate fits, that would still get a highlight.

| Gate | Coverage | Precision | Wrong highlights | Highlights on no-fit cases |
|---|---|---|---|---|
| Jev top probability ≥ 0.0 | 100% (42/42) | 100% (42/42) | 0 | 100% (8/8) |
| Jev top probability ≥ 0.3 | 100% (42/42) | 100% (42/42) | 0 | 100% (8/8) |
| Jev top probability ≥ 0.4 | 100% (42/42) | 100% (42/42) | 0 | 100% (8/8) |
| Jev top probability ≥ 0.5 | 100% (42/42) | 100% (42/42) | 0 | 75% (6/8) |
| Jev top probability ≥ 0.6 | 100% (42/42) | 100% (42/42) | 0 | 62% (5/8) |
| Jev top probability ≥ 0.7 | 98% (41/42) | 100% (41/41) | 0 | 62% (5/8) |
| Jev top probability ≥ 0.8 | 98% (41/42) | 100% (41/41) | 0 | 38% (3/8) |
| Jev top probability ≥ 0.9 | 90% (38/42) | 100% (38/38) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.95 | 86% (36/42) | 100% (36/36) | 0 | 0% (0/8) |
| Jev confidence ≥ 0.5 | 100% (42/42) | 100% (42/42) | 0 | 75% (6/8) |
| Jev confidence ≥ 0.7 | 98% (41/42) | 100% (41/41) | 0 | 50% (4/8) |
| Jev confidence ≥ 0.9 | 88% (37/42) | 100% (37/37) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.6 and any-fits Noul ≥ 0.5 | 98% (41/42) | 100% (41/41) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.6 and any-fits Noul ≥ 0.7 | 90% (38/42) | 100% (38/38) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.8 and any-fits Noul ≥ 0.5 | 98% (41/42) | 100% (41/41) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.8 and any-fits Noul ≥ 0.7 | 90% (38/42) | 100% (38/38) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.9 and any-fits Noul ≥ 0.5 | 90% (38/42) | 100% (38/38) | 0 | 0% (0/8) |
| Jev top probability ≥ 0.9 and any-fits Noul ≥ 0.7 | 88% (37/42) | 100% (37/37) | 0 | 0% (0/8) |
| Recommended: TargetRanking.suggestion() defaults (top ≥ 0.8, any-fits ≥ 0.5) | 98% (41/42) | 100% (41/41) | 0 | 0% (0/8) |
| Jev top Choice pick's own Noul ≥ 0.5 | 100% (42/42) | 100% (42/42) | 0 | 12% (1/8) |
| Jev top Choice pick's own Noul ≥ 0.7 | 98% (41/42) | 100% (41/41) | 0 | 0% (0/8) |
| Baseline softmax top ≥ 0.5 (reference) | 79% (33/42) | 76% (25/33) | 8 | 38% (3/8) |
| Baseline softmax top ≥ 0.7 (reference) | 55% (23/42) | 83% (19/23) | 4 | 38% (3/8) |
| Baseline softmax top ≥ 0.9 (reference) | 29% (12/42) | 92% (11/12) | 1 | 12% (1/8) |

## Latency

Wall clock per request from the harness (sequential, one request per case, all questions in one request). 150 successful requests over 3 pass(es).

| p50 | p95 | max | mean | warm-up (first request, excluded) | mean input tokens |
|---|---|---|---|---|---|
| 159 ms | 210 ms | 332 ms | 163 ms | 188 ms | 1871 |

99% (148/150) of requests finished within the 300 ms budget.

Top pick identical across 3 passes in 96% (48/50) of cases.

## No-fit cases

| Case | Jev top pick | p | any-fits Noul | its own Noul |
|---|---|---|---|---|
| nofit-bank-without-bank-targets | Scout (Champion) | 0.78 | 0.04 | 0.35 |
| nofit-ledger-without-ledger-targets | Fjordbank Web (Champion) | 0.44 | 0.07 | 0.32 |
| nofit-figma-other-client | Scout Site (Champion) | 0.82 | 0.19 | 0.25 |
| nofit-finder | Scout (Champion) | 0.70 | 0.04 | 0.28 |
| nofit-recipes-without-kitchen | Fjordbank Web (Champion) | 0.47 | 0.01 | 0.01 |
| nofit-personal-note | Scout (Champion) | 0.57 | 0.36 | 0.39 |
| nofit-slack | Apiary (Champion) | 0.88 | 0.25 | 0.67 |
| nofit-preview-without-nectar | Fjordbank Web (Champion) | 0.81 | 0.08 | 0.34 |

## Jev misses

| Case | Tags | Correct | Jev picked | p | Correct at rank |
|---|---|---|---|---|---|

## Baseline misses

| Case | Tags | Correct | Baseline picked |
|---|---|---|---|
| record-hotkey-settings | similar-name, no-name | scout-hotkeys (Session) | Scout (Champion) |
| whisper-download | no-name | scout-transcriber (Session) | Scout (Champion) |
| picker-misclick | no-name, recent-wrong | Scout: smart target suggestion (Jev) + safe send (Project) | Scout (Champion) |
| jev-suggestion-wrong | named | Scout: smart target suggestion (Jev) + safe send (Project) | Ledger (Champion) |
| fjord-recurring-payment | no-name | Fjordbank: payments redesign (Project) | Fjordbank: onboarding v3 (Project) |
| nectar-public-flag | no-name | nectar-cli (Session) | Nectar (Champion) |
| hive-cells-generic | no-name | Honeybee (Champion) | hive-transcripts (Session) |
| scout-site-download | similar-name, no-name | Scout Site (Champion) | Scout (Champion) |
| vague-short | no-name, vague | fjord-payments-table (Session) | Fjordbank Web (Champion) |
| transcript-names-wrong-thing | named, decoy-word | scout-transcriber (Session) | scout-hotkeys (Session) |
