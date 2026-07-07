# Issue #88 — Bug: lost refresh response permanently revokes the token family → silent sign-out

**Triage:** bug · ready-for-agent

**Created:** 2026-07-07 · **Source:** auth security/quality review 2026-07-07 (both reviewers flagged; top-level code-verified `refresh.py:155-167` + `AuthService.swift`)

**Severity:** high — a dropped network response mid-refresh (the primary driving use-case: cellular blip) silently signs a Sign-in-with-Apple user out and drops them to anonymous. No theft occurred.

## Problem

Refresh-token rotation has no reuse-grace window. Per RFC 9700 the backend revokes the **whole token family** the moment an already-used refresh token is replayed (`refresh.py:155-167`). That is correct defence against a stolen token, but it also punishes the honest client on a lost response:

1. iOS posts `/auth/refresh` with its current refresh token.
2. Backend commits the rotation (marks token `used_at`, mints a successor) — then the response is lost (`session.data` throws, timeout, connection drop).
3. iOS classifies this as `.transient` and **keeps the old refresh token** (`AuthService.swift:307-311` — correct on its own: a 5xx/timeout must not orphan the session).
4. Next 401 → iOS refreshes with that now-`used` token → backend sees `used_at` set → `RefreshReuseDetected` → family revoked → 401 → `.rejected` → re-bootstrap as anonymous. For a signed-in user this fires `authSignedInSessionDropped`.

The two sides are each individually reasonable; the gap is the missing **immediate-successor grace** on the server.

## Evidence (code-verified 2026-07-07)

- `app/auth/refresh.py:154-167` — `if row.used_at is not None:` unconditionally revokes the whole family and raises `RefreshReuseDetected`. No distinction between replay of the *immediately-previous* token (successor still unused = lost-response) and replay of an *older* token (genuine theft).
- `apps/ios-app/Hangs/Hangs/Services/AuthService.swift:288-313` — `performRefreshOrBootstrap`: `.transient` keeps stored tokens for retry (`:307-311`); `.rejected` (only on HTTP 401) re-bootstraps and, if previously signed in, logs `authSignedInSessionDropped` (`:295-305`).
- `RefreshOutcome` split (`AuthService.swift:317-356`): only a 401 is `.rejected`; 5xx/timeout/offline/decode = `.transient` — so the client correctly cannot tell "my successor exists but I never received it".

## Recommendation (root-cause, backend)

Store the successor linkage so the immediately-previous used token can be recognised, and return the existing successor instead of revoking when it is still unused:

- On replay of a used token **whose successor is still unused and unrevoked** → grant recovery, do **not** revoke the family. This is the lost-response case.
- On replay of a used token **whose successor has already been used** (or an older token in the chain) → keep the current behaviour: revoke the whole family (genuine reuse — the chain has moved on without this holder).

**Correction (2026-07-07, code-verified during session-split):** "return that successor (idempotent re-issue)" is **not implementable** — raw refresh tokens are never persisted, only their SHA-256 hash (`refresh.py:26-27,76`), so the already-minted successor's raw token cannot be handed back. Correct grace action: **revoke the dangling unused successor** (it was never delivered) **and mint a fresh rotation from the presented row** (same `family_id`, same family-deadline clamp), returning the new pair.

Bound the grace so it can't be abused: only the single most-recent used token qualifies, **and** only within a short window — config knob `REFRESH_RETRY_GRACE_SECONDS` (default 60) checked against `row.used_at`. Preferred lookup needs **no migration**: the successor is the same-family row with the smallest `issued_at` strictly greater than the presented row's `issued_at` (rotation stamps both with the same `now`). The `successor_token_hash` column variant would need Alembic `0005` = founder deploy heads-up — avoid. Keep the whole decision under the existing `with_for_update` lock (+ `FOR UPDATE` on the successor) so an honest retry and an attacker replay serialize. *(Folded in from the deleted draft `issue-88-refresh-rotation-retry-grace.md`.)*

## Acceptance

- [ ] Replay of the immediately-previous used token whose successor is still unused, within the grace window → fresh token pair returned (dangling successor revoked), family **not** revoked, client recovers transparently
- [ ] Replay of an older used token, OR a used token whose successor is already used → family revoked (theft path unchanged)
- [ ] Unit test: lost-response scenario (rotate, discard response, re-present old token) → recovery, not sign-out
- [ ] Unit test: genuine reuse (present token two rotations old) → family revoked
- [ ] iOS behaviour unchanged (still keeps tokens on `.transient`); no client change required, or a one-line follow-up only if the contract needs it
- [ ] Existing refresh-rotation tests stay green

## Notes

- Do not weaken the theft defence to fix this — the fix must keep revoking on genuine reuse. RFC 9700 explicitly permits a short reuse-grace for exactly this lost-response case.
- Cross-refs #61 (Sign in with Apple), #62 (cross-device binding — same refresh surface).
