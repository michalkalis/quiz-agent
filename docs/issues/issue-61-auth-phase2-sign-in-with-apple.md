# Issue #61 — Auth Phase 2: Sign in with Apple (optional real account)

**Triage:** enhancement · ready-for-human (auth/security + Apple secrets — maker≠checker)
**Reversibility:** c · new `users` table + Apple token exchange + `.p8` Fly secret + account-deletion endpoint — **NOT blind-overnight eligible** (auth + secret handling; human-reviewed, coordinated with #50).
**Status:** Spun off 2026-06-17 from #58 research §6 Phase 2 + founder decisions §8b. Phase 2 of 3. **Depends on #60.**

> Plan + decisions: [`docs/research/auth-research-2026-06-16.md`](../research/auth-research-2026-06-16.md) §4 (iOS flow), §6 (Phase 2), §5 (privacy endpoints). Research issue: [#58](issue-58-authentication.md).

## Why

Phase 1 (#60) fixes the freemium bypass on an anonymous identity. Phase 2 adds a **durable, recoverable real account**:

- Cross-device identity — a user can reinstall / switch iPhone and recover quiz history + premium by signing in again.
- IAP entitlements bind to `apple_sub`, which survives reinstall (the anchor #50 needs).
- Satisfies App Store Guideline 4.8 if a second login (Google, etc.) is ever added.
- Provides the mandatory in-app **Delete Account** (Guideline §5.1.1(v) + GDPR Art. 17) and **Export** (Art. 20).

**iOS-only MVP** (founder decision §8b #2): Sign in with Apple only; **email magic link deferred**. The self-issued-JWT token layer stays provider-agnostic so magic link is cheap to add later — do **not** adopt anything Apple-only at the token layer.

## Scope

**Backend (`apps/quiz-agent`):**
- New table: `users(id UUID PK, apple_sub TEXT UNIQUE, email TEXT, plan_tier TEXT, created_at TIMESTAMPTZ)`. **Coordinate schema with #50** so it satisfies IAP binding too.
- `POST /api/v1/auth/apple`: verify the Apple identity token against Apple JWKS (`https://appleid.apple.com/auth/keys`, cache 24h), validate nonce, exchange `authorization_code` for an Apple refresh token (ES256 client_secret JWT, max expiry ~6 months / 15,777,000 s), upsert the user row, **merge the anonymous usage history** from `anon_id`→`apple_sub`, return a server-issued JWT.
- `POST /api/v1/auth/refresh` — standard token refresh.
- `DELETE /api/v1/auth/me`: delete user row + usage + quiz history; call `https://appleid.apple.com/auth/revoke` with the stored Apple refresh token (required by §5.1.1(v) + GDPR Art. 17 — "without undue delay", not a fixed 30 days; see §7).
- `GET /api/v1/auth/me/export`: GDPR Art. 20 export.
- Client-secret generation utility (PyJWT + `.p8`). **Key ID + Team ID + `.p8` stored as Fly secrets.**

**iOS (`apps/ios-app`):**
- Add "Sign in with Apple" capability (Signing & Capabilities).
- `AuthService`: nonce generation (32 random bytes, SHA-256), `ASAuthorizationAppleIDProvider` credential flow, `getCredentialState` on cold launch, `credentialRevokedNotification` observer, anonymous→Apple upgrade request.
- In-app **Delete Account** UI in Settings (mandatory before submission) + **Export my data**.
- App Store privacy nutrition-label update.

## Size & dependencies

**Size: M–L** — Apple client_secret generation + token revocation are the trickiest parts.
**Depends on:** #60 (auth middleware + `anon_id` must exist to merge).
**Also depends on / coordinate with #50** (StoreKit IAP binding): `apple_sub` is the purchase anchor — align the `users` schema with both.

## Tasks (atomic)

- [ ] 61.1 — Alembic migration: `users` table (schema reviewed against #50 IAP needs).
- [ ] 61.2 — Apple identity-token verifier (JWKS RS256, 24h cache, nonce validation).
- [ ] 61.3 — Apple client_secret generator (PyJWT + `.p8`); `.p8`/Key ID/Team ID as Fly secrets.
- [ ] 61.4 — `POST /auth/apple`: authorization_code exchange → upsert user → **merge anon usage** → issue JWT.
- [ ] 61.5 — `DELETE /auth/me` (cascade delete + Apple `/auth/revoke`) and `GET /auth/me/export`.
- [ ] 61.6 — iOS Sign in with Apple capability + `AuthService` credential flow, nonce, credential-state/revocation observers, anon→Apple upgrade.
- [ ] 61.7 — iOS Settings: in-app Delete Account (with confirm) + Export; privacy nutrition label.
- [ ] 61.8 — Tests: pytest for apple verify / merge / delete+revoke / export (mock Apple endpoints); iOS unit tests for the credential flow (mocked).

## Acceptance

- [ ] A user with anonymous usage signs in with Apple → their prior daily usage + history is **merged**, not lost.
- [ ] `DELETE /auth/me` removes all user data **and** revokes the Apple token (verified against a mocked `/auth/revoke`).
- [ ] `GET /auth/me/export` returns the user's data (Art. 20).
- [ ] Reinstall + sign in recovers premium status (entitlement keyed to `apple_sub`).
- [ ] In-app Delete Account is reachable in ≤2 taps from Settings and confirms before deleting.
- [ ] pytest + iOS unit suites green; **human security review** signed off (feeds #48 Stage 2).

## Open / deferred

- `.p8` rotation (6-month max): decide **who rotates** — Ralph (automatable Fly secret set) vs human-calendared. Resolve when this issue is specced (founder decision §8b #5).
- Supabase Auth (Frankfurt, 50k MAU free) remains the acknowledged escape hatch if self-managed auth ops get burdensome — not adopted now.

## Cross-refs

- #58 (parent) · #60 (Phase 1 prerequisite) · #50 (IAP — `apple_sub` anchor; align schema) · #48 (security review) · #62 (Phase 3 cross-device + full binding).
