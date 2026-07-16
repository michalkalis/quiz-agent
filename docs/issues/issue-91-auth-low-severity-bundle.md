# Issue #91 — Auth low-severity hardening bundle (2026-07-07 review)

**Triage:** bug · done (2026-07-16)

**Created:** 2026-07-07 · **Source:** auth security + quality review 2026-07-07

**Severity:** low — six independent small items surfaced by the review; none exploitable in isolation, all cheap one-spot fixes. Bundled per the "one-sweep" pattern (cf. #82). Each is independently committable.

## Items

### 1. `SecRandomCopyBytes` return value ignored in SIWA nonce generation
`apps/ios-app/Hangs/Hangs/Services/AuthService.swift:390-393` — `_ = SecRandomCopyBytes(...)`. On failure the buffer stays all-zero → a predictable Sign-in-with-Apple nonce (the replay-defence primitive). Rare, one-line fix.
**Fix:** guard `== errSecSuccess`, else abort the sign-in.

### 2. `/usage/{user_id}` is unauthenticated (IDOR / info disclosure)
`app/api/routes/misc.py:65-73` — any caller can read any subject's `questions_used`, limit, and `is_premium` by supplying a `user_id`. Subjects are non-enumerable UUIDs and the data is low-sensitivity, but it is another user's account state with no auth and no rate limit.
**Fix:** derive the subject from the bearer (like `/auth/me`) instead of the path param, or at minimum require `require_auth_or_grace` + rate-limit.

### 3. Admin key compared with `!=` (non-constant-time)
`app/api/routes/misc.py:87` (`admin_key != expected_key`) and `app/api/admin.py:45` (`x_admin_key != admin_key`) — plain string inequality, unlike the Apple nonce check which correctly uses `hmac.compare_digest` (`apple.py:124`). Remote timing extraction of a high-entropy key is very hard, but it's an easy inconsistency.
**Fix:** `hmac.compare_digest(...)` in both places.

### 4. Server-error detail leaked to client on 500s
`app/api/routes/sessions.py:69` and `quiz.py:99, 180` return `detail=f"...: {str(e)}"`. Raw exception text (can include DB/internal messages) is echoed to the client. Auth endpoints correctly avoid this; these game routes don't. *(Corrected 2026-07-07: `quiz.py:142` originally listed here is NOT a leak — it raises a constructed no-questions-match diagnostic with no exception text; leave it.)*
**Fix:** log `str(e)`, return a generic 500 detail.

### 5. `/auth/apple` 409 after code exchange is unrecoverable
`app/api/routes/auth.py:348-349, 459-462` — `_merge_anonymous_identity` can raise 409 *after* `exchange_authorization_code` consumed Apple's single-use code; a retry then fails forever. Edge case (anon already folded elsewhere — near-impossible for one device).
**Fix:** either exchange the code after the merge-conflict check, or return a recoverable error that re-initiates the SIWA flow rather than a dead 502.

### 6. `attest_challenges` / used `refresh_tokens` never pruned
`app/auth/attest_challenge.py`, `app/auth/refresh.py` — rows only get `used_at`/`revoked_at` set, never deleted → unbounded table growth. Housekeeping, not correctness.
**Fix:** a periodic delete-where-expired (background task or a simple bounded cleanup on write).

## Acceptance

- [x] Item 1: nonce generation aborts sign-in on RNG failure (no all-zero buffer) — guard on `errSecSuccess`, `fatalError` on CSPRNG failure (call sites are `SignInWithAppleButton.onRequest`, a sync closure with no error channel; proceeding with a forgeable nonce is worse than crashing); + sanity unit test (64-char hex, unique per call)
- [x] Item 2: **already shipped before this sweep** — `/usage/{user_id}` was replaced by bearer-derived `/usage/me` in #96 P1 (`bd0f4e7`, deployed 2026-07-13; guard test `test_usage_me.py`). This sweep only fixed two stale doc-comments still naming the old path
- [x] Item 3: both admin-key checks use `hmac.compare_digest` on **bytes** (str compare raises TypeError on a non-ASCII header → client-triggerable 500); + new `test_admin_key_verify.py` pinning the second gate incl. the non-ASCII case
- [x] Item 4: game-route 500s return generic detail, real error only in logs (`sessions.py` gained the missing `logger.error`)
- [x] Item 5: merge-conflict 409 pre-checked BEFORE `exchange_authorization_code`, so the deterministic conflict no longer burns Apple's single-use code; locked in-transaction check kept as the authoritative race guard; + test pinning "zero exchange calls on 409"
- [x] Item 6: cleanup-on-write pruning — attest challenges expired >1 day swept on `issue()`, refresh-token rows from families past their absolute age cap swept on `rotate()`/`revoke_family()` (bounded batches of 500, no scheduler, no migration); grace re-issue additionally clamped to the live token's own expiry so a concurrent prune can never resurrect a family past its cap; + prune tests
- [x] Backend suite green (385 passed) + targeted iOS auth tests green (AppleAuthTests 5/5)

## Notes

Cross-refs #61 (Sign in with Apple), #65 (endpoint auth), #60 (App Attest / anonymous identity). Prod has no real users yet, so none of these is urgent — do as one sweep before the paid launch.

**Follow-up surfaced by the item-4 sweep (out of this bundle's scope, same defect class, WORSE — zero server-side logging):** `voice.py:61/63/65/188/190/193`, `tts.py:48/50/107/151/198`, `misc.py:64` all echo `str(e)` into the HTTP detail with no `logger` call. Fixing detail-only would silently drop the diagnostics, so they need the same log-then-generic treatment as item 4 — file as a small standalone sweep.

**iOS UX follow-up (optional):** the client shows the same generic "try again" banner for a 409 (deterministic — retry can never succeed) as for a transient 502; a 409-aware message ("already linked to another account") would stop pointless retries.
