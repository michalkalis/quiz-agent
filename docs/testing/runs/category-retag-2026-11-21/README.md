# Category re-tag, 2026-11-21

Moved every approved and pending question out of `general`, an id no picker offers, and moved the non-food rows out of `food-everyday`. Only the category field changed.

- `rollback.tsv`: 929 rows with question id, old category, new category, language and review status. To roll back, apply the file with the old and new columns swapped.
- `definitions.md`: the category rules the classifiers and the reviewer used. The generation prompt uses the same rules (`apps/quiz-pack-api/app/generation/classification.py`).
- `spot-check.tsv`: blind review by a fresh agent of 85 random rows (60 from `general`, 25 from `food-everyday`).

## Result

- Moved 826 `general` rows: history 243, geography-world 161, science-nature 202, entertainment 99, movies-music 46, food-everyday 38, sports 37.
- Moved 103 `food-everyday` rows: science-nature 51 (food chemistry and the biology of food, which the rules file under science), history 34, geography-world 13, entertainment 5.
- 1 row was not moved: `c5c561a0-…` (cs, pending review, Harry Potter). It has no embedding, and the write path would have called the embedding API. It stays in `general`.
- 0 approved questions remain in `general`.
- The classification was read by Sonnet agents, with no API calls. Language variants (cross-language embedding neighbours) were aligned to the same category.
- Spot-check, first pass: 14.1 % disagreement, almost all on food science and on what a custom originally meant. The rules were tightened and every row was classified again.
- Spot-check, second pass: 4.7 % disagreement (4 of 85). In 1.2 % (1 of 85), our category was not even the reviewer's second choice.

## How it was applied

`POST /api/v1/admin/questions/set-category` returned 500 in prod: its sync store facade hits a "Future attached to a different loop" error. The same steps (`store.get`, set the category, `store.upsert`, stored embedding reused) were therefore run inside the quiz-agent container on the async `PgvectorQuestionStore`. Two guards were in place: an embedder that refuses any call, and a compare step that skips a row unless its current category equals the old category in the file.

Every column of all 929 rows was compared before and after, including embedding hashes and translation status. Nothing changed except `category`.
