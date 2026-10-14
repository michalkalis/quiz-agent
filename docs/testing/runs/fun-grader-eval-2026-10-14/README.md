# Fun-grader feasibility check (2026-10-14)

Question: can a Claude grader, conditioned on the founder's taste, predict his blind fun ratings on questions it never saw? Method from claude.dev "Automating eval design and hillclimbing" (2026-09-28): held-out split, grader run twice for noise, checkable yes/no claims instead of a scale, gate before any hillclimb.

- Data: `../prompt-ab-2026-10-14/founder_ratings_all.json`, 474 scored questions; deterministic split by question hash → 317 train / 157 test.
- Grader: Opus 5.5 on the Claude Code subscription (`claude -p`, no tools, outside the repo). Prompt = founder's known likes/dislikes + 48 train examples (12 per score band) with his real scores and his Slovak notes where he left one; 8 yes/no claims + predicted score; 20 questions per call, 2 runs.
- Gate for a hillclimb: pooled Spearman ≥ 0.40 with CI lower bound > 0.24.

## Result: gate failed, no hillclimb

| Metric | Value |
|---|---|
| Pooled Spearman (test, n=157) | **0.20** (95 % CI 0.06–0.34) |
| Within-round Spearman | 0.23 |
| Run-to-run agreement (grader noise) | 0.94 |
| Bottom-30 % filter | catches 6/16 of his ≤5, drops 11/57 of his ≥9 |
| Best single claim | "tellable" +0.13; his stated dislikes (Russia, years, comparisons) ≈ 0 |

Same ceiling as every earlier grader (#165 D21, #166 D21b, #201, #203: ≤ 0.24). The grader is consistent (0.94), so the gap is not noise: it reliably disagrees with him. Even his own stated dislikes barely move his scores in this data, so a rubric built from them can't work either. The founder's blind sample stays the only fun gate.

Re-run: `python3 run_eval.py run && python3 run_eval.py score` (results cached per batch in `results/`).
