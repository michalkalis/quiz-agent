# Recategorize off-taxonomy prod questions — 2026-10-10

#198 — redesign color fixes, track 198.1 (category data). Founder approved in-session.

- `mapping.csv` — every approved / pending_review row whose category was outside the 7-id taxonomy: id, old → new category, question excerpt. Only `category` changed.
- `dump_offtaxonomy.py` — read-only prod query that produced the set (and verifies 0 afterwards).
- `apply_on_machine.py` + `apply_payload.json` — applied through `POST /api/v1/admin/questions/set-category`.
- Revert: the endpoint only accepts taxonomy ids, so restoring `old_category` needs a direct `UPDATE questions SET category = … WHERE id = …` per `mapping.csv` row.

## Archived (founder decision, same day)

- `7512e937-eb99-410e-992c-d3134e77e260` (An-225 destroyed near Kyiv in 2022): `approved` → `archived` via `POST /api/v1/admin/questions/review-status` (current-war content rule). Its sk/cs translations stay `approved` in `question_translations` but are only looked up for a question already selected by `review_status`, so they are no longer served. Restore: same route with `status: approved`.
