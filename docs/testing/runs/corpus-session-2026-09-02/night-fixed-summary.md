# Night batch 2026-09-02/03 — fixed batch summary (2026-09-03)

Source: `night-all.json` (82 q = batches night-01..09 minus 7 near-duplicates; rating batch 353c88ca). Night run used the pre-#71 CLI (v2_cot prompt, no answerability, no craft guards); fact-check ran on session:opus.

Fixes applied → `night-fixed.json`:
- PR #76 normaliser (after review fixes): 14 open questions with inline options → MCQ; 4 MCQ stems stripped of enumerated options; 0 unmatched; Arctic tern left untouched (no grammatical rewrite). Result 51 open / 31 MCQ.
- Offline answerability replay (session:haiku, `replay/`): 82 checked, 3 flagged, all kept after review — vanilla (hand-pollinate = correct), lightning (distance = correct) are comparator false positives; chainsaw (childbirth vs model "amputation") is a known misconception, web fact-check passed, founder 9/10.

Founder ratings (20/82): avg 9.15 — 13×10, 4×9, 8, 6 (rodent MCQ, stem now fixed), 3 (afternoon-heat "why the delay" — drop).
