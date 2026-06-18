# Issue #60 — Auth Phase 1: Server-Trusted Anonymous Identity

**Triage:** enhancement · ready-for-agent (Part A) / ready-for-human (Part B) — auth/security, maker≠checker
**Reversibility:** c · DB migration + auth middleware (+ App Attest in Part B) — staged behind a 30-day legacy-`user_id` grace path so the in-field app keeps working. Part A is loop-eligible; Part B (App Attest) is **device-only, human-reviewed** (per #57 Track F).
**Status:** Spun off from #58 research §6 (Phase 1) + founder decisions §8b. **Re-reviewed & corrected 2026-06-18** against fresh research (RFC 9700 refresh-token BCP, Apple App Attest server flow, FastAPI/PyJWT) + first-hand codebase inspection. Foundation — #49 (limits) and #50 (IAP) depend on this.

> Source of truth: [`docs/research/auth-research-2026-06-16.md`](../research/auth-research-2026-06-16.md) §6, §8b, **§10 (2026-06-18 corrections)**. Research issue: [#58](issue-58-authentication.md).

---

## Why (corrected after codebase inspection)

The freemium limit is untrustworthy. **Two of the original three premises were corrected** by reading the actual code (see §10 of the research doc):

1. **Daily count is in-memory and resets for free.** `app/usage/tracker.py` keeps a plain `dict` keyed on a client-supplied string, guarded by a `threading.Lock`. It wipes on every server restart/deploy. (The ratings DB lives on a persistent Fly volume, but the usage tracker specifically does **not** — it is pure in-memory.)
2. **Identity is a spoofable client string, not a trusted subject.** The app sends `user_id` as a JSON body field on `POST /api/v1/sessions`. It is `"dev_" + 16 hex chars` (a 20-char string, generated in `PersistenceStore.swift:120`), **not a UUID**, and carries no proof of origin. Changing the string → a fresh 20-question bucket.
3. **CORRECTION — `setPremium` is already admin-guarded.** `POST /api/v1/usage/{user_id}/premium` (`app/api/routes/misc.py:64`) already requires an `X-Admin-Key` header matching `ADMIN_API_KEY`; it is **not** open. The original "anyone can self-grant premium" claim was wrong. The real residue: the iOS `setPremium()` call sends **no** admin key (dead path), and premium will be granted by IAP (#50), not the client. **→ Phase 1 must NOT replace the admin-key guard with "any valid bearer" — that would be a downgrade.** Leave `setPremium` admin-only; remove/retire the dead iOS call.

**What Phase 1 actually fixes:** make *identity* server-trusted (derive the subject from a signed token, not from a spoofable body field) and make the daily count *persistent*. That alone closes the freemium bypass and unblocks #49/#50. No managed auth provider — self-owned tokens on the existing FastAPI + Postgres + Fly stack. The token layer stays provider-agnostic so email magic-link / Android stay cheap to add later (founder §8b #2).

---

## Architecture decisions (resolved 2026-06-18)

These were ambiguous or wrong in the prior draft; resolved here so the loop has no forks.

- **D1 — Persistence: existing Postgres (`DATABASE_URL`, asyncpg, region `cdg`) + introduce Alembic to `apps/quiz-agent`.** *Why robust, not just simple:* (1) the new tables hold real auth/user data that evolves across #60→#61→#62 — versioned migrations are required; `create_all` can only add tables, never `ALTER`. (2) Postgres is the only store here that is concurrent-write-safe and multi-region-portable (the founder's global goal; the reason self-JWT was chosen). (3) It is **not new infra** — this Postgres already serves the question store in prod, and `apps/quiz-pack-api` already has a working Alembic setup to copy. *Do not* put auth tables in the ratings SQLite (single-region, no `ALTER`), and *do not* use `create_all` against the async DB — `app/main.py:186` documents that it dies with `MissingGreenlet`. New data access is async (asyncpg), consistent with `PgvectorQuestionStore`.
- **D2 — JWT library: PyJWT** (not python-jose; python-jose is unmaintained — FastAPI's own tutorial moved to PyJWT). Add `pyjwt[crypto]` to `apps/quiz-agent` deps. *(Flag: the python-jose CVE id cited in research is unverified — don't quote a CVE number without re-checking; the "use PyJWT" direction is solid and confirmed by FastAPI docs.)*
- **D3 — Signing: HS256 now, isolated for a future swap to ES256.** Single service that both signs and verifies → symmetric HS256 is acceptable **if** the secret is ≥64 chars from a CSPRNG, stored as a Fly secret `AUTH_JWT_SECRET` (never hardcoded). Put all sign/verify in one small module so moving to ES256 (when a second service must verify, e.g. quiz-pack-api) is a one-file change. **On verify always pass an explicit `algorithms=["HS256"]` allowlist** — this single habit closes the `alg=none` and algorithm-confusion attacks.
- **D4 — Subject id type is `TEXT`, not `UUID`.** New identities are UUID strings, but the 30-day grace path must accept the legacy `"dev_…"` ids, which are **not** UUIDs. A `UUID` column would reject them at insert. All subject columns are `TEXT`; this also matches the current tracker's `str` keys.
- **D5 — Refresh-token rotation + reuse detection (RFC 9700 `MUST` for native/public clients).** A static long-lived refresh token is non-compliant. Each `/refresh` issues a **new** refresh token and invalidates the old; replay of an already-used token → revoke the whole token *family* (theft signal) and force re-bootstrap. Refresh tokens stored **hashed** (SHA-256 of a 32-byte opaque random value); access JWTs stay stateless.
- **D6 — Rate-limit key must be the real client IP.** `slowapi`'s default `get_remote_address` returns the **Fly proxy IP** (`app/rate_limit.py`), so a per-IP limit would be global/useless. Key the bootstrap limiter on the `Fly-Client-IP` header instead.
- **D7 — App Attest is split into Part B** (see below) — it is device-only (cannot run on the simulator that the whole iOS test loop uses), so it cannot be part of the loop-able deliverable. The loop-able foundation (Part A) ships first; App Attest lands right after as a device-tested, human-reviewed step. This honors founder §8b #1 (App Attest *is* in Phase 1) while keeping Part A genuinely loop-ready.

---

## Part A — Loop-ready foundation (identity + persistence)

**Daily-reset timezone:** keep the existing behavior — `datetime.now(timezone.utc).date()` (UTC midnight). Document it; do not change reset semantics in this issue (minimal footprint). *Known product question, out of scope here:* for SK users the free limit resets ~01:00–02:00 local — revisit if it confuses testers.

### Backend (`apps/quiz-agent`)

**Tables (Alembic migration, Postgres):**
- `anonymous_identities(anon_id TEXT PK, created_at TIMESTAMPTZ, last_seen_at TIMESTAMPTZ, is_legacy BOOL DEFAULT false, upgraded_to_user_id TEXT NULL)` — `anon_id` holds new UUID strings *and* legacy `dev_…` ids.
- `refresh_tokens(token_hash TEXT PK, family_id UUID, anon_id TEXT, issued_at TIMESTAMPTZ, expires_at TIMESTAMPTZ, used_at TIMESTAMPTZ NULL, revoked_at TIMESTAMPTZ NULL)` — rotation + family-based reuse detection (D5).
- `daily_usage(subject_id TEXT, usage_date DATE, questions_count INT, is_premium BOOL, PRIMARY KEY(subject_id, usage_date))` — replaces the in-memory dict; `subject_id` is `TEXT` (D4).

**Endpoints + middleware:**
- `POST /api/v1/auth/anon-bootstrap` — mints `{access_token (JWT, HS256, 15 min, claims iss/sub=anon_id/aud/exp/iat/jti), refresh_token (opaque, ~60-day absolute, ~30-day sliding)}`. Part A gate = IP rate-limit on `Fly-Client-IP` (D6) + creates the `anonymous_identities` row. (App Attest gate added in Part B.)
- `POST /api/v1/auth/refresh` — rotation (D5): hash-lookup the presented refresh token; reject if expired/revoked; if `used_at` is already set → **revoke the whole `family_id` and 401**; else mint a new access+refresh pair in the same family and mark the old one used (atomic transaction).
- Auth dependency (`Depends`) extracting `subject_id` from `Authorization: Bearer` (verified with the explicit `algorithms` allowlist, D3). **Grace (flag `LEGACY_USER_ID_GRACE`, default on):** if no bearer, fall back to the body/path `user_id` for 30 days, auto-creating an `is_legacy=true` identity row; when the flag is off, unauthenticated requests are rejected.
- `setPremium`: **leave the existing `X-Admin-Key` guard unchanged** (it is already correct, §10 correction). Do not route it through the bearer middleware.

**Usage tracker:** migrate `UsageTracker` to read/write `daily_usage` (async asyncpg) instead of the in-memory dict. Keep the public method names (`check_limit`, `record_question`, `get_usage`, `set_premium`, `is_premium`) but they become `async`; update the call sites in the sessions route. Preserve the lazy daily-reset semantics (reset when `usage_date < today`).

### iOS (`apps/ios-app`)

- New `AuthService` **actor** owning Keychain reads/writes (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — works while the screen is locked during a drive; **no biometric flags**). Use `@MainActor`/actor isolation — never `nonisolated(unsafe)`.
- First launch (no Keychain token): call `/auth/anon-bootstrap`, store access + refresh in Keychain. During grace, the existing `dev_…` id is still sent so usage continues uninterrupted.
- Extend `NetworkService` to attach `Authorization: Bearer <access>` on all requests; on 401 → single-flight refresh (one shared `Task` dedupes concurrent refreshes) → retry the original request once; if refresh fails → re-bootstrap. `QuizViewModel` unchanged.
- Retire the dead `setPremium()` client call (it sends no admin key and always 401s).
- Add `PrivacyInfo.xcprivacy` (declare UserDefaults required-reason `CA92.1`) — blocks submission if missing.

### Tasks (Part A — atomic, loop-able)

- [x] 60.1 — Set up Alembic in `apps/quiz-agent` (copy the `quiz-pack-api` pattern, async/asyncpg) + migration for `anonymous_identities`, `refresh_tokens`, `daily_usage`. *Done 2026-06-18: `app/db/{base,engine,models}.py`, `alembic/` scaffold, migration `0001_auth_phase1`. Verified — models map cleanly, offline DDL renders correct TEXT/TIMESTAMPTZ/UUID + FK/indexes, 100 existing tests still collect, ruff clean. **Not yet applied to live DB** (`alembic upgrade head` needs Postgres access — run at deploy time).*
- [x] 60.2 — Token module (PyJWT, HS256, isolated sign/verify, explicit `algorithms` allowlist, full claim set incl. `jti`); `AUTH_JWT_SECRET` as a Fly secret (≥64-char CSPRNG). *Done 2026-06-18: `app/auth/tokens.py` (`TokenService`, algorithm + min-secret length isolated in one module), `AUTH_JWT_*` settings. 10 unit tests green incl. expiry/tamper/issuer/audience/wrong-secret rejection and the `alg=none` confusion attack. Secret still to be set as a Fly secret at deploy.*
- [ ] 60.3 — Refresh-token store: opaque random → SHA-256 hash, `family_id`, rotation + reuse-detection (atomic).
- [ ] 60.4 — `POST /auth/anon-bootstrap` (IP rate-limited on `Fly-Client-IP`) + `POST /auth/refresh` (rotation).
- [ ] 60.5 — Migrate `UsageTracker` to `daily_usage` (async Postgres), public names stable, lazy UTC reset preserved; update sessions-route call sites.
- [ ] 60.6 — Auth `Depends` middleware: subject from bearer; `LEGACY_USER_ID_GRACE` 30-day fallback (flag both ways). **Do not** touch the `setPremium` admin-key guard.
- [ ] 60.7 — iOS `AuthService` actor: Keychain store, bootstrap-on-first-launch, token model.
- [ ] 60.8 — iOS `NetworkService`: bearer on all requests + 401→single-flight-refresh→retry→re-bootstrap; retire dead `setPremium()`; add `PrivacyInfo.xcprivacy`.
- [ ] 60.9 — Tests (all sim/CI-runnable): pytest — bootstrap mints valid JWT; refresh rotates & invalidates old; **reused refresh → family revoked + 401**; expired/invalid → 401; usage persists across a simulated restart (re-instantiate tracker on the same DB); subject derived from token not body; grace flag both ways; `setPremium` still admin-only. iOS unit — `AuthService` Keychain store/retrieve (mocked), bootstrap-on-first-launch, 401→single-flight-refresh, re-bootstrap on refresh failure.

### Acceptance (Part A)

- [ ] Restarting the backend does **not** reset a user's daily count (persisted in `daily_usage`).
- [ ] A request whose subject comes from a valid bearer token is counted against *that* subject; sending a different `user_id` body field can no longer mint a fresh bucket once grace is off.
- [ ] `/auth/refresh` rotates the refresh token; replaying an old (used) refresh token revokes the family and returns 401.
- [ ] A legacy body `user_id` (no bearer) still succeeds **during** the grace window and is rejected after it (flag-controlled, testable both ways).
- [ ] iOS cold launch mints + stores tokens in Keychain; subsequent requests carry the bearer; a forced 401 transparently refreshes (single-flight, no duplicate refreshes).
- [ ] `setPremium` still returns 401 without the admin key (guard unchanged).
- [ ] `PrivacyInfo.xcprivacy` present; pytest + iOS unit suites green.

---

## Part B — App Attest (device-only, after Part A; human-reviewed)

**What App Attest is, plainly:** Apple's way for our server to verify that a request really comes from *our genuine app* running on a *real iPhone*, not from a script impersonating it. Without it, someone could call `anon-bootstrap` directly and mint unlimited anonymous identities. It is the lock that makes the self-issued anonymous token hard to forge (founder §8b #1).

**Why it is separate from the loop:** App Attest needs the iPhone's Secure Enclave and **does not work on the iOS Simulator** (`DCAppAttestService.isSupported` is false there). The whole automated iOS test loop runs on the simulator, so the real attestation can only be verified on a physical device, by hand. The backend verification *can* be unit-tested with recorded fixtures, but the end-to-end flow is device-only.

**The flow (corrected — the prior draft omitted the handshake entirely):**
1. `POST /api/v1/auth/attest-challenge` — server returns a one-time random challenge (stored, short TTL, single-use). **Mandatory** — a client-generated nonce gives zero replay protection.
2. One-time **attestation** (first install): client `generateKey()` → `keyId`, attests over `SHA256(challenge)`; server verifies the cert chain against the **pinned** Apple App Attest root CA, checks nonce = `SHA256(authData ‖ SHA256(challenge))`, `keyId == SHA256(publicKey)`, `rpIdHash == SHA256(TeamID.BundleID)`, `counter == 0`, and the `aaguid` matches the expected **environment** (dev vs prod — mismatch fails silently, the #1 gotcha). Store `app_attest_keys(key_id, anon_id, public_key, sign_counter, environment)`.
3. Ongoing **assertion**: `anon-bootstrap` requires a valid assertion over a fresh challenge before minting; verify the signature with the stored public key and that the **sign counter strictly increased** (replay guard), updating it transactionally.

**Library:** prefer **`pyattest` ≥ 1.0.4** (maintained Sept 2025; pin ≥1.0.4, v1.0.1 was yanked) — **audit its step coverage before relying on it**; fall back to raw `cbor2` + `cryptography` if the audit is unsatisfactory.

**Dev/test bypass (must be prod-excluded):** server feature flag `APP_ATTEST_REQUIRED` (off in dev/test, on in prod); iOS skips attestation under `#if targetEnvironment(simulator)` (compile-time, so the bypass is physically absent from the production binary — not a runtime `if`).

### Tasks (Part B — NOT loop-eligible; device + human verify)

- [ ] 60.10 — `app_attest_keys` migration + `POST /auth/attest-challenge` (single-use, TTL).
- [ ] 60.11 — Attestation verifier (pyattest, audited; cert-chain pin, nonce, keyId, rpId, counter==0, env/`aaguid`) + key storage.
- [ ] 60.12 — Gate `anon-bootstrap` on a valid assertion (counter strictly-increasing, transactional); `APP_ATTEST_REQUIRED` flag (prod on, dev/test off).
- [ ] 60.13 — iOS App Attest: `DCAppAttestService` key + attestation on first launch, assertion on bootstrap, `#if targetEnvironment(simulator)` compile-time bypass; handle `attestKey()` Apple round-trip failures (retry + graceful degrade).
- [ ] 60.14 — Tests: pytest with recorded attestation/assertion fixtures (CI-runnable); **real device end-to-end = `[HUMAN]`** (not sim-verifiable).

### Acceptance (Part B)

- [ ] `anon-bootstrap` rejects a request with a missing/invalid assertion when `APP_ATTEST_REQUIRED=on`.
- [ ] Replaying an assertion (non-increasing counter) is rejected.
- [ ] Dev/test path works with the flag off and the simulator bypass; the production build contains no bypass (compile-time excluded).
- [ ] Backend verifier unit tests green; **real-device attestation confirmed by a human** (Slovak device, per `[[user_device_ios26]]`).
- [ ] **Human security review** (maker≠checker) signed off before merge — feeds #48 Stage 2.

---

## Size & dependencies

**Size: L** — Part A is the bulk of loop-able work (Alembic setup + token/refresh + tracker migration + iOS networking); Part B (App Attest) adds the device-only hardening.
**Depends on:** nothing — this is the foundation.
**Unblocks:** #49 (server-side daily limit), #50 (IAP binds to this identity).
**EU residency:** satisfied — `DATABASE_URL` Postgres + both Fly apps are `primary_region = "cdg"` (Paris). No migration.

## Open / deferred to later phases

- `.p8` Apple key rotation and the Supabase escape-hatch are **Phase 2 (#61)** notes (founder §8b #5).
- Sign in with Apple (real account, cross-device) is **#61**; full IAP binding is **#62**.
- Daily-reset local-timezone question (above) — product call, not blocking.

## Cross-refs

- #58 (research/plan parent, see §10 corrections) · #49 (limits, now enforceable) · #50 (IAP — ship premium as an auto-renewable subscription so it launches on anonymous identity, §8b #3) · #48 (security review gate) · #57 (loop verification — Part B is not loop-eligible).
