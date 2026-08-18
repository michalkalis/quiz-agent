# Frozen eval sets

Permanent human-rated question sets. Every prompt/model/layer change should be
measured against these instead of running a new rating round.

## d21-2026-08.jsonl (#165)

88 questions from the D21 round (issue-164, batch `c1f109ec`, rated 2026-08-18).
Built by `apps/quiz-pack-api/scripts/build_d21_eval_set.py` from
`docs/testing/runs/d21-round-2026-08-15/`; deterministic join on `qid`.

Per row:

- **Label (primary):** `michal_score` 1–10 — the product axis (fun/playability
  while driving). Scoring layers are judged by Spearman against this.
- **Flags (editorial axis):** `flags.fact_error` / `logic_flaw` / `stale` /
  `duplicate`, classified from svitlanka's comments
  (`svitlanka_flags.json` in the run dir holds the classification rules).
  Detection layers (verify, critique red-flags) are judged by **recall/precision
  against the 10 error-flagged rows** — never by Spearman.
  `duplicate` rows (14) are a design artifact of the D21 round (arms shared
  facts, published without dedupe): exclude them from quality Spearman, use
  them for dedupe tests. `svitlanka_score_raw` is provenance only, not a label.
- **Layers:** replayed verdicts of critique / duels / answerability / judges /
  verify for calibration baselines.

Evaluate with `apps/quiz-pack-api/scripts/eval_d21_set.py`:

- no args → baselines. Default excludes duplicate rows; `--include-duplicates`
  reproduces the original D21 numbers on all 88 (judges panel Spearman .242,
  answerability .219, critique .192, verify recall 0.4 = 4/10 at
  `likely_wrong`).
- `--scores file.json` → evaluate a new layer: `{qid: number}` for a scoring
  layer (Spearman vs michal) or `{qid: bool}` for a detection layer
  (recall/precision vs error flags).
