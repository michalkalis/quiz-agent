# Issue #90 — Bug: freemium monthly quota is TOCTOU — concurrent starts can exceed the limit

**Triage:** bug · ready-for-agent

**Created:** 2026-07-07 · **Source:** auth quality review 2026-07-07 (`quiz.py:60-75, 147-148`)

**Severity:** medium — under-enforces the paywall (a few questions over the cap), never locks a user out. Low blast radius.

## Problem

Quota enforcement is a read-then-write across two separate calls with no atomic guard: `check_limit` reads the current count, then `record_question` increments it. Between them there is no lock. Two concurrent `POST /start` (or two answers) at count 99 both pass `check_limit`, both call `record_question`, and the user reaches 101 for a 100-question monthly cap.

It only ever lets a user do a little *more* than allowed — it can't wrongly lock anyone out — so it's a paywall-integrity issue, not an availability one.

## Evidence (code-verified 2026-07-07)

- `app/api/routes/quiz.py:60-75` — `check_limit` gate, then later `record_question` (`:147-148`) as a distinct call; no shared lock or atomic conditional.
- The monthly window (#87) sums daily rows; the increment is a separate upsert.

## Recommendation (root-cause)

Enforce the cap in the **same** atomic write as the increment: have `record_question` perform the upsert and return the post-increment count (or a conditional update that increments only while under the limit), and reject when the returned count exceeds the limit. This collapses check-and-record into one atomic operation, removing the window. Keep the pre-check for the fast-path error message if desired, but the authoritative gate must be the atomic increment.

## Acceptance

- [ ] Two concurrent start/answer requests at the boundary → total recorded never exceeds the limit
- [ ] Normal single-request flow and error copy unchanged (`quota_limit_reached`)
- [ ] Concurrency test: N parallel records at count `limit-1` → exactly `limit` recorded, the rest rejected
- [ ] Existing quota tests (#87) stay green

## Notes

- Do not paper over it with an in-process lock — enforce atomically at the store layer so it holds across workers/instances on Fly.
- Cross-refs #87 (monthly free quota), #89 (null-subject bypass — same enforcement surface).
