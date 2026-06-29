# Issue #61 — Execution plan + ready-to-paste session prompts

**Created:** 2026-06-27 — from a code-recon session (two Explore agents mapped the full Phase 1 / #60 backend + iOS state so future sessions don't re-map). #61 is large (8 tasks) and **sensitive** (auth + Apple secrets, `ready-for-human`, reversibility `c`) — so it's split into session-sized, independently-committable chunks. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go.

> Parent plan: [`issue-61-auth-phase2-sign-in-with-apple.md`](issue-61-auth-phase2-sign-in-with-apple.md). Plan review (F1–F10): [`../artifacts/issue-61-plan-review-2026-06-26.html`](../artifacts/issue-61-plan-review-2026-06-26.html).

---

## Recon snapshot — what Phase 1 (#60) already gives us

**Backend (`apps/quiz-agent`):**

- **Migrations** in `alembic/versions/`. **Head = `0002_app_attest`** (down from `0001_auth_phase1`). Style: `op.create_table` + `sa.Text()`, `sa.DateTime(timezone=True)` for TIMESTAMPTZ, `sa.LargeBinary()` for BYTEA, `postgresql.UUID(as_uuid=True)` for UUID. Both existing migrations are short — read them for the exact idiom before writing `0003`.
- **Models** in `app/db/models.py` — SQLAlchemy 2.0 `Mapped[...]` / `mapped_column()`. `Base` + `utcnow()` in `app/db/base.py`. Async engine (`asyncpg`) in `app/db/engine.py`.
- **Existing auth tables:** `anonymous_identities(anon_id PK TEXT, created_at, last_seen_at, is_legacy, upgraded_to_user_id TEXT NULL)` · `refresh_tokens(token_hash PK, family_id UUID, anon_id FK, …)` · `daily_usage(PK = (subject_id, usage_date), questions_count INT, is_premium BOOL)` · `attest_challenges` · `app_attest_keys`.
  - ⚠️ **`daily_usage` is keyed on `subject_id`, NOT `anon_id`** (the plan text says `anon_id` — it's wrong). `subject_id` = the JWT `sub`; for an anon user that's the `anon_id`. The F3 merge folds the anon's `subject_id` rows into the new `users.id` rows.
- **JWT** in `app/auth/tokens.py` (`TokenService`): PyJWT **HS256**, secret `AUTH_JWT_SECRET` (≥64 chars). Claims `iss/sub/aud/iat/exp/jti`; **`sub` = identity subject** (anon today → `users.id` after Apple sign-in). Access TTL 900s. `decode_access_token` already pins `algorithms=["HS256"]` + a `require` list.
- **Refresh** in `app/auth/refresh.py` (`RefreshTokenStore`): SHA-256 `token_hash`, `secrets.token_urlsafe(32)`, RFC-9700 rotation + family-revoke on reuse.
- **Identity dep** in `app/auth/identity.py`: `AuthSubject(subject_id, is_legacy, authenticated)`, `resolve_session_subject(...)`, `require_authenticated_subject(...)`. FastAPI wiring in `app/api/deps.py` (`require_auth`, `get_token_service` ← `app.state.token_service`).
- **App Attest** in `app/auth/app_attest.py` (`AppAttestService`); routes in `app/api/routes/auth.py` mounted at `/api/v1`. Response model `AuthTokenResponse(access_token, refresh_token, token_type, expires_in, anon_id)`. Endpoints rate-limited 20/min per IP.
- **Config** in `app/config.py` — a custom `@dataclass(frozen=True)` with `Settings.from_env()` (plain `os.getenv`), **not** pydantic-settings. New env vars go here.
- **Tests** in `tests/`: `conftest.py` `db_sessionmaker` fixture hits a **real Postgres** at `TEST_DATABASE_URL` (drop+create per test; auto-skips if the env var is unset). Pure-unit example: `test_auth_tokens.py`. Integration: `httpx.AsyncClient(transport=ASGITransport(app=...))`; services injected on `app.state.*`.
- **Deps already present** (`pyproject.toml`): `pyjwt[crypto]`, `httpx`, `cryptography` (gives Fernet + ES256/RS256), `cbor2`, `pyattest`, `asyncpg`. **Nothing new to install.**

**iOS (`apps/ios-app`, Xcode project "Hangs"):**

- `Services/AuthService.swift` — `actor AuthService`. Anon bootstrap; `KeychainTokenStore` persists one `AuthTokens{accessToken, refreshToken, anonId}` JSON blob, accessibility `AfterFirstUnlockThisDeviceOnly`. `anonId` (JWT `sub`) is the **upgrade anchor**.
- `Services/NetworkService.swift` — `actor`, URLSession. `sendAuthorized()` is the single Bearer-injection point + 401→refresh retry. `Config.apiBaseURL`: prod `https://quiz-agent-api.fly.dev`, local `http://localhost:8002`.
- `Services/DeviceAttestService.swift` — `AppAttestor`, `DCAppAttestService`, code `#if !targetEnvironment(simulator)`.
- `Views/SettingsView.swift` — `groupSection(label:color:content:)` helper; **no account UI yet** → add an `accountGroup`.
- **No Sign in with Apple anywhere.** Both `Hangs-Prod.entitlements` and `Hangs-Local.entitlements` are empty `<dict/>` → must add `com.apple.developer.applesignin`. App identifiers: bundle `com.missinghue.hangs`, team `KAGWHPZZFQ`.
- Tests: `HangsTests/AuthServiceTests.swift` + `AuthAttestTests.swift`, **Swift Testing** (`import Testing`), mocks `AuthStubURLProtocol` / `MockTokenStore` / `MockAttestor`.

---

## Locked decisions (carry into every session)

| # | Decision |
|---|---|
| **F1/F2** | Apple refresh token stored **encrypted at rest** in `users.apple_refresh_token_encrypted BYTEA NULL`, **Fernet** (from `cryptography`, no new dep). Key = Fly secret `APPLE_TOKEN_ENC_KEY` (`Fernet.generate_key()`). Decrypt **only** at `DELETE /auth/me` to call revoke. Nullable → if Apple returns no refresh token, fall back to the TN3194 no-token revoke path; never block deletion. |
| **F3** | Anon→account merge: **one transaction** — resolve/insert `users` by `apple_sub`; check the anon's `upgraded_to_user_id` (== this user → no-op; other user → reject; unset → proceed); fold each `daily_usage` row **keyed on `subject_id`** into the user's `(users.id, usage_date)` row (`questions_count` **summed**, `is_premium` **OR**ed); set `upgraded_to_user_id = users.id`. **Sum, not max** (else sign-out/in resets the freemium limit). Idempotent via the flag. |
| **F5** | **Store the Apple name** → add `full_name TEXT NULL`, persist on first `/auth/apple` (Apple sends it once). *(Founder decision 2026-06-27.)* |
| **F6** | Nonce check = compare the id_token `nonce` claim against **`base64url-nopad(sha256(raw_nonce))`** — not raw, not hex. Most common bug in this flow. |
| **F7** | `/auth/apple` is **NOT** behind App Attest — a valid Apple identity token is a strong enough barrier. Deliberate, documented (vs Phase 1's anon-bootstrap which *is* attested). |
| **F4** | `DELETE /auth/me`: delete local data **immediately**; revoke is **best-effort** — on Apple-endpoint failure, log and move on (retry/queue is post-MVP), don't block the GDPR delete on Apple availability. |
| **F8** | **No `plan_tier`** — subscriptions deferred. Premium stays on `daily_usage.is_premium`; `apple_sub` is the durable anchor for the future entitlement model. |
| **F10** | Use the correct **TN3194** revoke URL slug (the `-implementing-` variant 404s). `id_token` expiry is 5–10 min → treat as short-lived, **don't hardcode**. `authorization_code` has a hard **5-min** limit → exchange immediately on the backend. |

**Audience note:** native iOS Sign in with Apple → the id_token `aud` is the **app bundle id** (`com.missinghue.hangs`), and the client_secret `sub` / token-exchange `client_id` is that same bundle id (not a Services ID). The verifier's audience check uses the bundle id.

**#50 coordination:** #50 is pack-purchasing only (non-consumable IAP), no DB schema of its own. `users.apple_sub UNIQUE NOT NULL` is a sufficient purchase anchor; actual receipt→`apple_sub` binding is #62. No schema change needed for #50.

---

## Session breakdown

| Session | Tasks | Risk | Notes |
|---|---|---|---|
| **A — Backend foundation** | 61.1 + 61.2 + 61.3 + unit tests | Low | Migration + models + Apple verifier + client_secret gen + Fernet helper + config. **No live endpoints, no outbound Apple calls, no prod secrets needed.** Fully unit-testable. Safe solo. |
| **B — `POST /auth/apple`** | 61.4 + integration tests | **High** | Token exchange + F3 merge + encrypt-store + issue JWT. The correctness core. Needs Apple sandbox secrets to E2E; mock for tests. |
| **C — Delete + Export** | 61.5 + tests | High | Cascade delete + Apple `/auth/revoke` (F4 best-effort, TN3194 fallback) + GDPR export. |
| **D — iOS SIWA** | 61.6 + 61.7 + iOS tests | Med | Entitlements + `AuthService` Apple flow + Settings account UI + privacy label. Depends on B/C being live. |
| *(E — optional)* | 61.8 final integration + #48 security-review prep | — | Fold into A–D where it fits; spin out only if needed. |

**Human prerequisites before B/C can deploy** (founder, in Apple Developer + Fly — give exact steps when B starts): enable the Sign in with Apple capability on the App ID; create a **Sign in with Apple key** (`.p8`) → note Key ID + Team ID (`KAGWHPZZFQ`); then set Fly secrets `APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_TEAM_ID`, `APPLE_SIGNIN_PRIVATE_KEY` (.p8 contents), `APPLE_SIGNIN_CLIENT_ID` (= `com.missinghue.hangs`), and `APPLE_TOKEN_ENC_KEY` (one `Fernet.generate_key()`). Session A needs **none** of these.

---

## Ready prompt — Session A (Backend foundation)

```
Work on issue #61 (Sign in with Apple), Session A only: backend foundation — tasks 61.1 + 61.2 + 61.3 + their unit tests. Do NOT build any endpoint (/auth/apple, delete, export) — that's Session B/C. Stop, commit, and push when A is green.

Read first (don't re-map the whole codebase — this is already known):
- docs/issues/issue-61-execution-prompts.md  → "Recon snapshot" + "Locked decisions" (F1–F10). Follow them exactly.
- apps/quiz-agent/alembic/versions/0001_auth_phase1_tables.py and 0002_app_attest_tables.py  → migration idiom; head is 0002_app_attest.
- apps/quiz-agent/app/db/models.py and app/db/base.py  → model style (SQLAlchemy 2.0 Mapped/mapped_column).
- apps/quiz-agent/app/auth/tokens.py  → TokenService style.
- apps/quiz-agent/app/config.py  → how settings/env vars are added (frozen dataclass + from_env, NOT pydantic-settings).
- apps/quiz-agent/tests/test_auth_tokens.py and tests/conftest.py  → unit + db_sessionmaker test patterns.

Build:
1) 61.1 — Alembic migration 0003 (down_revision "0002_app_attest"): table
   users(id UUID PK, apple_sub TEXT UNIQUE NOT NULL, email TEXT NULL, full_name TEXT NULL,
   apple_refresh_token_encrypted BYTEA NULL, created_at TIMESTAMPTZ NOT NULL).
   full_name = F5 (store Apple name). apple_refresh_token_encrypted = F1/F2 (Fernet ciphertext, BYTEA = sa.LargeBinary). NO plan_tier (F8). Add the matching SQLAlchemy model `User` to app/db/models.py. Verify `alembic upgrade head` then `downgrade` round-trips on a scratch DB.
2) 61.2 — Apple identity-token verifier (new module, e.g. app/auth/apple.py): fetch Apple JWKS (https://appleid.apple.com/auth/keys) via httpx, cache 24h, pick key by `kid`, verify id_token RS256, check iss=https://appleid.apple.com and aud=com.missinghue.hangs (bundle id), enforce exp. Validate nonce per F6: the token's `nonce` claim must equal base64url-nopad(sha256(raw_nonce_bytes)) — not raw, not hex. Return the verified claims (sub, email, etc.).
3) 61.3 — Apple client_secret generator (same module or app/auth/apple_client_secret.py): build an ES256 JWT signed with the .p8 (PyJWT), header kid=Key ID, claims iss=Team ID, sub=client_id (com.missinghue.hangs), aud=https://appleid.apple.com, iat/exp with exp ≤ ~6 months (15,777,000 s) capped. Add a small Fernet helper (encrypt/decrypt with APPLE_TOKEN_ENC_KEY) for Session B/C to reuse. Add the new env vars to app/config.py: APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_TEAM_ID, APPLE_SIGNIN_PRIVATE_KEY, APPLE_SIGNIN_CLIENT_ID, APPLE_TOKEN_ENC_KEY (all optional/None default so the app still boots without them).
4) Unit tests (mock Apple, no live calls): JWKS verify happy path + tampered sig + wrong aud/iss + expired + nonce match/mismatch (F6 exact form); client_secret has correct header.kid/claims and ≤6-month exp; Fernet round-trip; migration up/down. Mint test id_tokens with a throwaway RS256 keypair and stub the JWKS fetch (mirror how test_app_attest.py builds a synthetic cert tree).

Done = `cd apps/quiz-agent && pytest tests/ -v` green (new tests included), `alembic upgrade head` clean, ruff clean. Commit per logical step (migration; verifier; client_secret+config), push to main. Update docs/todo/TODO.md #61 line + tick 61.1/61.2/61.3 in issue-61-auth-phase2-sign-in-with-apple.md. This is auth code: fail loud, no silent skips.
```

---

## Ready prompt — Session B (`POST /api/v1/auth/apple`)

```
Work on issue #61 (Sign in with Apple), Session B only: the POST /api/v1/auth/apple endpoint (task 61.4) + integration tests. Session A (migration + Apple verifier + client_secret gen + Fernet helper) must be merged first. Stop, commit, push when green.

Read first: docs/issues/issue-61-execution-prompts.md ("Recon snapshot" + "Locked decisions", esp. F3/F6/F7/F10), apps/quiz-agent/app/api/routes/auth.py (route + AuthTokenResponse style, rate-limit pattern), app/auth/identity.py + app/auth/tokens.py (how sub/JWT is issued), app/auth/refresh.py (issue first refresh token in the same family), tests/test_auth_endpoints.py (ASGITransport integration pattern), and the Session A modules (verifier, client_secret, Fernet helper).

Build POST /api/v1/auth/apple. Request: { identity_token, authorization_code, raw_nonce, user? (first-login name/email) }. In ONE DB transaction:
1) Verify identity_token with the Session A verifier (RS256/JWKS, aud=bundle id, nonce per F6). Reject on failure → 401.
2) Exchange authorization_code at https://appleid.apple.com/auth/token (httpx, client_secret from Session A; immediate — 5-min code limit, F10). Capture the Apple refresh_token if present.
3) Upsert users by apple_sub (store email + full_name on first login, F5). 
4) Merge anon usage per F3: read anon_id from the caller's bearer (current sub); guard via anonymous_identities.upgraded_to_user_id (== this user → skip; other → 409; unset → proceed); fold daily_usage rows keyed on subject_id (the anon_id) into (users.id, usage_date): questions_count SUMMED, is_premium ORed; set upgraded_to_user_id = users.id. Idempotent.
5) Encrypt the Apple refresh token with the Fernet helper → users.apple_refresh_token_encrypted (F1/F2). Null if Apple returned none.
6) Issue a server JWT with sub = users.id (NOT the anon_id) + a first refresh token in a new family. Return AuthTokenResponse.
F7: this endpoint is deliberately NOT behind App Attest — add a one-line comment saying so.

Integration tests (mock Apple JWKS + /auth/token with respx or a stub transport): happy path merges usage (sum, not max); repeat call with same anon_id is a no-op (idempotent, no double-count); sign-out→fresh-anon→sign-in cannot reset the freemium limit; anon already upgraded to a different user → 409; missing/invalid id_token → 401; sub of the returned JWT == users.id.

Done = pytest tests/ -v green, ruff clean. Commit, push, tick 61.4. Coordinate the human Apple-secret setup if E2E is wanted (see execution-prompts "Human prerequisites").
```

---

## Ready prompt — Session C (Delete + Export)

```
Work on issue #61, Session C only: DELETE /api/v1/auth/me + GET /api/v1/auth/me/export (task 61.5) + tests. Sessions A+B merged first.

Read first: docs/issues/issue-61-execution-prompts.md (F1/F2/F4/F10), app/api/routes/auth.py, app/auth/identity.py (require_auth dep — these endpoints need an authenticated users.id subject), the Session A Fernet helper, tests/test_auth_endpoints.py.

Build:
- DELETE /api/v1/auth/me: authenticated (sub must be a users.id). In a transaction delete the user's data — users row, their daily_usage (subject_id = users.id), refresh-token families, and the merged anon trail as appropriate. Then revoke at Apple: decrypt apple_refresh_token_encrypted (Fernet) → POST https://appleid.apple.com/auth/revoke with client_secret + token. F4: delete local data immediately; revoke is best-effort — on failure log and return success (don't block GDPR delete on Apple availability). TN3194 no-token fallback if the column is null (F10 — correct slug, the -implementing- one 404s).
- GET /api/v1/auth/me/export: authenticated; return the user's data as JSON (GDPR Art. 20) — profile (apple_sub, email, full_name, created_at), usage history, derived premium state.

Tests (mock /auth/revoke): delete removes all rows AND calls revoke with the decrypted token; revoke-failure still deletes locally + returns success (F4); null refresh token → no-token fallback path, still deletes; export returns the expected shape.

Done = pytest green, ruff clean. Commit, push, tick 61.5.
```

---

## Before Session D — readiness gate (assessed 2026-06-27 · **all gaps cleared 2026-06-29**)

**Verdict (2026-06-29): ✅ READY for Session D.** All three blocking gaps are closed — Session D (iOS) can now be implemented *and* verified end-to-end. Original assessment + resolutions:

**Gap 1 — Account UI — ✅ RESOLVED 2026-06-29.** Designed in `design/quiz-agent.pen` in the existing card style (IBM Plex Mono `account` label in `$accent-teal`, `$bg-card` rounded card, Inter rows, `$border-subtle` dividers), placed after the audio-feedback section and before about — founder choice: a dedicated, balanced `account` section (not a top-of-screen promo). Three artifacts for Session D's 61.7 to build against:
- `NEW_Screen/Settings-SignedOut` (node `taml6`) — `account` card: one-line benefit (`Sign in to keep your premium and history when you reinstall.`) + standard black "Sign in with Apple" button (Apple logo, HIG style).
- `NEW_Screen/Settings-SignedIn` (node `JB9Oi`) — identity rows (name + private-relay email) + `Export my data` + `Sign out` + `Delete account` (`$accent-red`, destructive).
- `NEW_Screen/Settings-DeleteConfirm` (node `PmJ3A`) — iOS-style confirm dialog: "Delete account?" + body + Cancel / Delete (destructive). (Mockup copy is English to match the rest of the file; Slovak comes from app localization.)

**Gap 2 — Backend live — ✅ RESOLVED 2026-06-29.** Backend Sessions A–C deployed live (Fly **v53**, 2026-06-29); migrations `0003_users` + `0004_refresh_subject` applied to prod. (`fly.toml` still has **no `release_command`** — migrations were run manually this round; wire one in later if auto-migrate-on-deploy is wanted.)

**Gap 3 — Apple portal + secrets — ✅ RESOLVED 2026-06-29.** All five Fly secrets present: `APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_TEAM_ID`, `APPLE_SIGNIN_PRIVATE_KEY`, `APPLE_SIGNIN_CLIENT_ID`, `APPLE_TOKEN_ENC_KEY` — `/auth/apple` no longer 503s.

**Remaining sequence:** steps 1–3 (Apple `.p8` → deploy+secrets+migrations → account-UI design) are all **done**. Left: **(4) implement Session D** (61.6/61.7 + iOS tests) against the live backend + the Pencil design above → **(5) `[HUMAN]` real-device Slovak sign-in verify**.

---

## Ready prompt — Session D (iOS Sign in with Apple)

```
Work on issue #61, Session D only: iOS Sign in with Apple + account UI (tasks 61.6 + 61.7) + iOS unit tests. Backend Sessions A–C live on prod first.

Read first: docs/issues/issue-61-execution-prompts.md ("Recon snapshot" iOS section), apps/ios-app/Hangs/Hangs/Services/AuthService.swift (actor, KeychainTokenStore, AuthTokens, bootstrap/refresh single-flight), Services/NetworkService.swift (sendAuthorized Bearer injection), Services/DeviceAttestService.swift (nonce/SHA256 + #if !simulator idiom), Views/SettingsView.swift (groupSection helper), HangsTests/AuthServiceTests.swift (Swift Testing + AuthStubURLProtocol/MockTokenStore patterns), and both Hangs-*.entitlements (currently empty).

Build:
1) Add `com.apple.developer.applesignin` capability to Hangs-Prod.entitlements AND Hangs-Local.entitlements (array with "Default"). 
2) Extend AuthService for the Apple upgrade: generate a 32-byte random raw nonce, send base64url-nopad(sha256(raw_nonce)) as ASAuthorizationAppleIDRequest.nonce (per F6 — NOT hex; the backend verifier built in Session A compares against exactly this encoding), drive ASAuthorizationAppleIDProvider, on credential POST to /api/v1/auth/apple { identity_token, authorization_code, raw_nonce, user } using the CURRENT anon bearer (so the backend can merge), then swap the stored AuthTokens to the returned account tokens (sub = users.id). Add getCredentialState on cold launch + a credentialRevokedNotification observer that drops to a fresh anon identity. Keep the token layer provider-agnostic (no Apple-only types in AuthTokens).
3) SettingsView: new accountGroup — "Sign in with Apple" (when anon) / signed-in state + "Delete account" (confirm dialog, calls DELETE /auth/me, ≤2 taps) + "Export my data" (GET /auth/me/export). 
4) App Store privacy nutrition label update (note in the PR; the click-through is founder's in ASC).

Tests (Swift Testing, mock network via AuthStubURLProtocol): nonce is sha256-hashed before sending; successful Apple credential calls /auth/apple with the anon bearer and swaps tokens; delete clears tokens; revoked-credential notification re-bootstraps anon. Note real Sign in with Apple needs a device/entitlement — unit-test the AuthService logic with a mocked credential, not the system sheet.

Done = HangsTests green on the iPhone sim, build clean. Commit, push, tick 61.6/61.7. Real-device Slovak sign-in is a [HUMAN] verify step.
```

---

## Status

- ✅ Recon done (this doc). Decisions F1–F8 + F10 locked; F5 = store name (founder 2026-06-27).
- ✅ **Session A — Backend foundation DONE 2026-06-27** (commits `51540aa` 61.1, `30dddf5` 61.2, `1f2be31` 61.3). Full suite green (213 passed, 27 new), ruff clean, live alembic up/down/up round-trip OK. See "Session A delivered" below.
- ✅ **Session B — `POST /auth/apple` DONE 2026-06-27** (commits `8bad2c7` migration/model, `e5f10ae` OAuth client + token helper, `244f7e7` endpoint). Full suite green (234 passed, 21 new), ruff clean, live alembic up/down/up round-trip OK. See "Session B delivered" below.
- ✅ **Session C — Delete + Export DONE 2026-06-27** (`DELETE /auth/me` + `GET /auth/me/export` + `AppleOAuthClient.revoke`; 242 tests green, 8 new, ruff clean). See "Session C delivered" below.
- 🟢 Session D — iOS SIWA — **READY** (gate cleared 2026-06-29): account UI designed (`taml6` signed-out / `JB9Oi` signed-in / `PmJ3A` delete dialog), backend live v53, all 5 Apple secrets set. Paste the Session D prompt above to execute (61.6/61.7 + iOS tests).
- ✅ Human: Apple Sign in key (`.p8`) + all 5 Fly secrets DONE 2026-06-29 (v53 live). ⬜ `[HUMAN]` real-device Slovak sign-in verify still remains — after Session D lands.

### Session A delivered — exact symbols for B/C/D to import

- **61.1** `app/db/models.py::User` + `alembic/versions/0003_users_table.py` (revision `0003_users`, head). Reminder (recon): `daily_usage` is keyed on `subject_id`, not `anon_id`.
- **61.2** `app/auth/apple.py`: `AppleIdentityVerifier(audience=…, http_client=None)` → `await .verify(identity_token, raw_nonce=…)` returns claims or raises `AppleVerificationError`. Helpers: `expected_nonce_claim(raw_nonce)`, `build_apple_identity_verifier(settings)`.
- **61.3** `app/auth/apple_secrets.py`: `generate_client_secret(team_id, client_id, key_id, private_key, ttl_seconds=…, now=…)`; `AppleTokenCipher(key).encrypt/decrypt` + `build_apple_token_cipher(settings)`.
- **config**: `settings.apple_signin_client_id` (= bundle id, the verifier audience), `apple_signin_key_id`, `apple_signin_team_id`, `apple_signin_private_key`, `apple_token_enc_key` — all optional/None.

### Session B delivered — exact symbols + carry-forward for C/D

- **61.4** `app/api/routes/auth.py::apple_sign_in` (`POST /api/v1/auth/apple`, rate-limited 20/min/IP, **not** App-Attest-gated per F7). Request model `AppleSignInRequest{identity_token, authorization_code, raw_nonce, user?{name,email}}` + `get_apple_verifier`/`get_apple_oauth_client`/`get_apple_token_cipher` in `app/api/deps.py`; services built on `app.state` in `main.py` only when the full Apple key set is present (route 503s otherwise). Response is the existing `AuthTokenResponse` with `anon_id` = `users.id`.
- **outbound** `app/auth/apple_oauth.py`: `AppleOAuthClient(team_id, client_id, key_id, private_key, http_client=None, token_url=…)` → `await .exchange_authorization_code(code)` → `AppleTokenExchange(refresh_token: str|None)`, raises `AppleOAuthError`; `build_apple_oauth_client(settings)`. **Session C adds `.revoke(token)` here** (same client_secret + `_post_form`), and decrypts with the Session-A `AppleTokenCipher(settings.apple_token_enc_key).decrypt(...)`.
- **token helper** `TokenService.subject_from_token(token, *, allow_expired=False) -> str` (signature/iss/aud enforced; only expiry optional) — used to name the anon to merge.
- ⚠️ **Schema change for Session C — migration `0004_refresh_subject`** dropped the `refresh_tokens.anon_id → anonymous_identities` FK (and its `ON DELETE CASCADE`). `refresh_tokens.anon_id` is now a **generic subject id** (anon id *or* `users.id`). **Consequence: `DELETE /auth/me` must delete the user's `refresh_tokens` rows EXPLICITLY** (no cascade) — filter `refresh_tokens.anon_id == users.id`, plus `daily_usage` rows `subject_id == users.id`, plus the `users` row. The merged anon's own refresh tokens are already revoked at sign-in, and its `daily_usage` rows are folded+deleted into the user, so the "anon trail" to clean is mostly the `anonymous_identities` row (kept, `upgraded_to_user_id` points at the deleted user — decide in C whether to null/delete it).

> ⚠️ **NONCE (F6) — resolved in the Session D prompt.** The backend verifier enforces **F6**: the id_token `nonce` claim must equal `base64url-nopad(sha256(raw_nonce))` — not raw, not hex. The Session D prompt (step 2) now states this correctly. Keep it: any iOS change must send `base64url-nopad(sha256(raw_nonce))` as `ASAuthorizationAppleIDRequest.nonce`, never hex.

### Session C delivered — exact contract for Session D's account UI

- **61.5** `app/api/routes/auth.py`: `delete_account` (`DELETE /api/v1/auth/me`) and `export_account` (`GET /api/v1/auth/me/export`), both rate-limited 20/min/IP and gated by `require_auth`. Authority rule (`_resolve_account`): the bearer's `sub` **must be a `users.id`** — no/invalid bearer → **401**; an authenticated anon/legacy subject (no `users` row) → **404**.
- **DELETE** → **204 No Content** (empty body). One transaction deletes the `users` row + its `daily_usage` (`subject_id == users.id`) + its `refresh_tokens` (`anon_id == users.id`, explicit — no cascade after `0004`), and **nulls** `anonymous_identities.upgraded_to_user_id` for the merged trail. *After commit*, best-effort Apple revoke (F4): decrypt `apple_refresh_token_encrypted` → `AppleOAuthClient.revoke(token)`; any failure (or a null token) is logged and **still returns 204** — Apple availability never blocks the GDPR delete. iOS: a 2xx means "account gone, drop the stored account tokens and re-bootstrap a fresh anon".
- **EXPORT** → **200** JSON `AccountExportResponse`: `{ apple_sub, email, full_name, created_at, is_premium, usage: [{ usage_date, questions_count, is_premium }] }` (usage oldest-first; `is_premium` top-level = derived as of today). **No secret** is included (no field for the encrypted Apple refresh token).
- **outbound** `AppleOAuthClient.revoke(token, *, token_type_hint="refresh_token")` posts to `/auth/revoke` (correct TN3194 slug, F10), reusing the client_secret + a shared `_post` core; raises `AppleOAuthError` (the route swallows it). Apple returns an **empty 200** on success, so revoke does *not* parse a JSON body (unlike token exchange).
