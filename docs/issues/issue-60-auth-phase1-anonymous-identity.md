# Issue #60 — Auth Phase 1: Server-Trusted Anonymous Identity

**Triage:** enhancement · ready-for-human (auth/security — maker≠checker)
**Reversibility:** c · Postgres schema migration + auth middleware + App Attest — **NOT blind-overnight eligible** (auth/payment-adjacent per #57 Track F; human-reviewed before merge, staged behind a grace period).
**Status:** Spun off 2026-06-17 from #58 research §6 Phase 1 + founder decisions §8b. Phase 1 of 3. **Foundation — #49 (limits) and #50 (IAP) depend on this.**

> Plan + decisions: [`docs/research/auth-research-2026-06-16.md`](../research/auth-research-2026-06-16.md) §6 (Phase 1), §8b (founder decisions). Research issue: [#58](issue-58-authentication.md).

## Why

The freemium limit is currently untrustworthy and the premium grant is wide open:

- `UsageTracker` keeps the daily count **in-memory** — it wipes on every server restart, so the free limit resets for free.
- `POST /api/v1/usage/{userId}/premium` is **unauthenticated** — anyone can self-grant premium.
- The app sends `user_id` as a plain JSON body field with no proof of origin — trivially spoofable.

Phase 1 makes identity **server-trusted**: a self-issued JWT minted only after the request is proven to come from a genuine app build (App Attest), backed by persistent Postgres usage. No managed auth provider — self-owned JWT on the existing FastAPI/Fly.io + Postgres stack (chosen for global portability + zero incremental cost). The token layer stays provider-agnostic so email magic link / Android stay cheap to add later (founder decision §8b #2).

## Scope

**Backend (`apps/quiz-agent`):**
- New Postgres tables (Alembic migration):
  - `anonymous_identities(anon_id UUID PK, device_fingerprint TEXT, issued_at TIMESTAMPTZ, upgraded_to_user_id UUID NULLABLE)`
  - `refresh_tokens(token_hash TEXT PK, anon_id UUID, expires_at TIMESTAMPTZ)`
  - `daily_usage(user_id UUID, date DATE, questions_count INT, is_premium BOOL, PRIMARY KEY(user_id, date))` — replaces the in-memory dict.
- `POST /api/v1/auth/anon-bootstrap` — issues a long-lived refresh token + short-lived (15-min) access JWT (HS256, `anon_id` in `sub`). **Gated by App Attest** (founder decision §8b #1, STRONG NOW): verify the `DCAppAttestService` assertion before minting. IP rate-limit as defence-in-depth.
- `POST /api/v1/auth/refresh` — exchange refresh token for a new access JWT.
- Migrate `UsageTracker` to read/write `daily_usage` instead of the in-memory dict.
- `Depends` middleware extracting `user_id` from `Authorization: Bearer`. **Grace period:** also accept the legacy unauthenticated body `user_id` for **30 days** post-release (founder decision §8b #5), then drop the unauthenticated path.
- Guard `POST /api/v1/usage/{userId}/premium` with the auth middleware.

**iOS (`apps/ios-app`):**
- New `AuthService` actor owning Keychain reads/writes (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- App Attest key generation + assertion on first launch (`DCAppAttestService.shared`, supported on all iOS 18 deployment targets — verified §7).
- On first launch (no Keychain token): App Attest → `POST /auth/anon-bootstrap` → store tokens in Keychain.
- Extend `NetworkService` to attach `Authorization: Bearer <token>` on all requests + transparent refresh on 401. `QuizViewModel` unchanged.
- Add `PrivacyInfo.xcprivacy` manifest (non-optional — blocks App Store submission if missing).

## Size & dependencies

**Size: L** — grown from M because App Attest (`cbor2`/`cryptography` attestation verify + one Apple round-trip at first install) was pulled into Phase 1 (founder decision §8b #1, ~+1 week).
**Depends on:** nothing — this is the foundation.
**Unblocks:** #49 (server-side daily limit), #50 (IAP binds to the identity).
**EU residency:** already satisfied — both Fly apps `primary_region = "cdg"` (Paris). No migration.

## Tasks (atomic)

- [ ] 60.1 — Alembic migration: `anonymous_identities`, `refresh_tokens`, `daily_usage` tables.
- [ ] 60.2 — JWT issuance/verification utility (HS256, 15-min access, long-lived refresh, secret as Fly secret).
- [ ] 60.3 — App Attest verifier (`cbor2` + `cryptography`): validate attestation object + assertion server-side.
- [ ] 60.4 — `POST /auth/anon-bootstrap` (App-Attest-gated + IP rate-limited) and `POST /auth/refresh`.
- [ ] 60.5 — Migrate `UsageTracker` to `daily_usage` (persistent); keep the public interface stable.
- [ ] 60.6 — Auth `Depends` middleware + 30-day legacy `user_id` grace path; guard `setPremium`.
- [ ] 60.7 — iOS `AuthService` actor: App Attest key + assertion, Keychain store, bootstrap-on-first-launch.
- [ ] 60.8 — iOS `NetworkService`: bearer header on all requests + 401→refresh; `PrivacyInfo.xcprivacy`.
- [ ] 60.9 — Tests: pytest for bootstrap/refresh/grace/setPremium-guard (mock App Attest); iOS unit tests for `AuthService` Keychain + refresh (mocked).

## Acceptance

- [ ] Restarting the backend does **not** reset a user's daily count (persisted in `daily_usage`).
- [ ] `POST /api/v1/usage/{userId}/premium` returns 401 without a valid bearer token.
- [ ] `anon-bootstrap` rejects a request with a missing/invalid App Attest assertion.
- [ ] A request carrying a legacy body `user_id` (no bearer) still succeeds **during** the grace window and is rejected after it (flag-controlled, testable both ways).
- [ ] iOS cold launch mints + stores a token in Keychain; subsequent requests carry the bearer; a forced 401 transparently refreshes.
- [ ] `PrivacyInfo.xcprivacy` present; pytest + iOS unit suites green.
- [ ] **Human security review** (maker≠checker) signed off before merge — feeds #48 Stage 2.

## Open / deferred to later phases

- `.p8` Apple key rotation and Supabase escape-hatch are **Phase 2 (#61)** notes (founder decision §8b #5).
- Sign in with Apple (real account, cross-device) is **#61**; full IAP binding is **#62**.

## Cross-refs

- #58 (research/plan parent) · #49 (limits, now enforceable) · #50 (IAP — ship premium as auto-renewable subscription so it launches on anonymous identity, §8b #3) · #48 (security review gate) · #57 (loop verification — auth is not blind-overnight eligible).
