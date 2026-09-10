# Corpus session batch 1 — founder ratings (2026-09-02)

Run: `LLM_GATEWAY=session generate_pack.py --dry-run --target-count 5` (default CLI flags, pre-parity-fix — CLI used the old `v2_cot` prompt and the session:sonnet verifier; see PR fix/169-cli-prod-parity). Scale 1–10.

| # | Question (short) | Rating | Founder note |
|---|---|---|---|
| 1 | Sharks vs trees: older? | 8 | — |
| 2 | Sequence 2, 6, 12, 20, 30, … | 7 | — |
| 3 | Radar engineer, melted pocket item → microwave | 6 | Badly built: the famous thing (microwave) should be the answer; nobody guesses "chocolate bar". |
| 4 | Venus: day vs year, which is longer | 4 | Answer is guessable — "year" would be a boring answer, question would make no sense otherwise. |
| 5 | Sealed honey in Egyptian tombs still edible | — | Known refuted myth (D21b q91, founder verdict 2026-08-26, wiki-first). Session verifier passed it citing an aggregator site. |

Calibration signals for generation/scoring:
- Reverse-engineer pattern: the well-known artefact must be the answer, not the obscure trigger detail.
- Comparison-bet pattern: reject when one option is obviously the "boring" answer (the question only makes sense one way).
