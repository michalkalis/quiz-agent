# Issue #91 — Auth low-severity hardening bundle (2026-07-07 review)

**Triage:** bug · ready-for-agent

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
`app/api/routes/sessions.py:69` and `quiz.py:99, 142, 180` return `detail=f"...: {str(e)}"`. Raw exception text (can include DB/internal messages) is echoed to the client. Auth endpoints correctly avoid this; these game routes don't.
**Fix:** log `str(e)`, return a generic 500 detail.

### 5. `/auth/apple` 409 after code exchange is unrecoverable
`app/api/routes/auth.py:348-349, 459-462` — `_merge_anonymous_identity` can raise 409 *after* `exchange_authorization_code` consumed Apple's single-use code; a retry then fails forever. Edge case (anon already folded elsewhere — near-impossible for one device).
**Fix:** either exchange the code after the merge-conflict check, or return a recoverable error that re-initiates the SIWA flow rather than a dead 502.

### 6. `attest_challenges` / used `refresh_tokens` never pruned
`app/auth/attest_challenge.py`, `app/auth/refresh.py` — rows only get `used_at`/`revoked_at` set, never deleted → unbounded table growth. Housekeeping, not correctness.
**Fix:** a periodic delete-where-expired (background task or a simple bounded cleanup on write).

## Acceptance

- [ ] Item 1: nonce generation aborts sign-in on RNG failure (no all-zero buffer)
- [ ] Item 2: `/usage` no longer discloses arbitrary subjects (bearer-derived or auth+rate-limited)
- [ ] Item 3: both admin-key checks use constant-time compare
- [ ] Item 4: game-route 500s return generic detail, real error only in logs
- [ ] Item 5: `/auth/apple` conflict is recoverable (no permanently-dead single-use code)
- [ ] Item 6: expired attest challenges and used/revoked refresh tokens are pruned
- [ ] Backend suite + targeted iOS auth tests green

## Notes

Cross-refs #61 (Sign in with Apple), #65 (endpoint auth), #60 (App Attest / anonymous identity). Prod has no real users yet, so none of these is urgent — do as one sweep before the paid launch.
