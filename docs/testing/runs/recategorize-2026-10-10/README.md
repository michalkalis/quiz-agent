# Recategorize off-taxonomy prod questions — 2026-10-10

#198 — redesign color fixes, track 198.1 (category data). Founder approved in-session.

- `mapping.csv` — every approved / pending_review row whose category was outside the 7-id taxonomy: id, old → new category, question excerpt. Only `category` changed.
- `dump_offtaxonomy.py` — read-only prod query that produced the set (and verifies 0 afterwards).
- `apply_on_machine.py` + `apply_payload.json` — applied through `POST /api/v1/admin/questions/set-category`.
- Revert: the endpoint only accepts taxonomy ids, so restoring `old_category` needs a direct `UPDATE questions SET category = … WHERE id = …` per `mapping.csv` row.
