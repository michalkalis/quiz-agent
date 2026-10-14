# Archive of the 2026-10-01 bulk batch (#203 — boring questions)

The founder decided on 2026-10-14 to archive the whole 2026-10-01 bulk run. A blind sample scored ~2/10. 942 rows were archived (en; 933 approved, 9 pending_review), `review_status` → `archived`, in one transaction.
- Serving filters on status at query time, so the change was live immediately.
- `archived_ids.json` lists every id with its previous status.
- To restore, set `review_status` back to the stored status for those ids.

Live stock right after: approved en 370 · sk 91 · cs 98; pending_review en 253 (TestFlight only).
Older unrated batches (July to 2026-09-17, 345 rows) stay as they are (founder 2026-10-14).
