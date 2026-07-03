# Issue #61 — Auth Phase 2: Sign in with Apple (optional real account)

**Triage:** enhancement · ready-for-human (auth/security + Apple secrets — maker≠checker)
**Reversibility:** c · new `users` table + Apple token exchange + `.p8` Fly secret + account-deletion endpoint — **NOT blind-overnight eligible** (auth + secret handling; human-reviewed, coordinated with #50).
**Status:** Spun off 2026-06-17 from #58 research §6 Phase 2 + founder decisions §8b. Phase 2 of 3. **Depends on #60.** Plan review 2026-06-26 incorporated — F1–F3 resolved + `plan_tier` dropped (subscriptions deferred); see *Resolved design decisions*. **2026-06-27: code recon done + split into 4 session-sized chunks with ready-to-paste prompts → [`issue-61-execution-prompts.md`](issue-61-execution-prompts.md)** (also locks F4/F5/F6/F7). **2026-06-29: backend Sessions A–C done + deployed live (Fly v53), all 5 Apple Fly secrets set, account UI designed in Pencil (`taml6`/`JB9Oi`/`PmJ3A`). Session D (iOS — 61.6/61.7/61.8) is now READY to execute — the Session-D readiness gate is fully cleared.** See the Prep progress block below + the execution-prompts readiness gate.

> Plan + decisions: [`docs/research/auth-research-2026-06-16.md`](../research/auth-research-2026-06-16.md) §4 (iOS flow), §6 (Phase 2), §5 (privacy endpoints). Research issue: [#58](issue-58-authentication.md).

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session. This issue's prep was hand-driven before the orchestrator existed; the 2026-06-29 `/prepare-issue` run did only the **remaining** step — closing the Session-D readiness gate by designing the account UI.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | code recon + prior-art in execution-prompts; `auth-research-2026-06-16.md` |
| 2 · Plan              | ✅ done | `## Why` / `## Scope` / `## Resolved design decisions` |
| 3 · Plan review       | ✅ done | plan review 2026-06-26 — F1–F3 resolved, `plan_tier` dropped |
| 4 · Impl-plan         | ✅ done | `## Tasks` 61.1–61.8 + `## Acceptance` |
| 5 · Impl-plan review  | ✅ done | Session-D readiness gate (2026-06-27) — **all 3 gaps cleared 2026-06-29** |
| 6 · Split             | ✅ done | `issue-61-execution-prompts.md` — Sessions A/B/C/D |

**Last updated:** 2026-06-30 · **Next:** `[HUMAN]` on-device Slovak sign-in verify + privacy nutrition label (App Store Connect) + human security review (feeds #48). · **Gate attempts:** P3 1/3 · P5 1/3
**Verification pass 2026-06-30** (founder-requested "is it done & correct?"): backend code correct on all F1–F7 (verified first-hand with code quotes), live on Fly **v54**, all 5 Apple secrets deployed, `/auth/apple` returns 422 not 503 (wired); the quiz-agent backend test job is **green in CI** against a real Postgres (the red "Backend CI" badge is the unrelated quiz-pack-api integration flake). iOS code correct (entitlements wired via xcconfig, nonce F6 byte-exact, account UI ≤2 taps). **Found + fixed one Session-D miss:** `SettingsViewOnboardingTests.replayClosureFires` instantiated `SettingsView` without the now-required `AppState` env object (siblings were updated, this one missed) — a genuine correctness fix, committed `c9f09de`. **Correction to my own first call:** I initially blamed this test for the red iOS CI — that was wrong. iOS CI's "Build and Test iOS App" job has been **red on every run since ~Jun 15 (pre-#61)**, caused by the pre-existing snapshot tests in `HangsTests/Snapshots/` (HomeView/QuestionView/ResultView/Paywall) failing on stale `.txt` references — **non-gating per `ios.md`** (a snapshot diff is a re-record signal, not a hard block). All tests are Swift Testing, so xcodebuild's legacy "Executed 11 tests, 0 failures" line doesn't surface those failures → the "0 failures + TEST FAILED" signature. **Net: the red badge is not a #61 regression and the fix doesn't change it.** The authoritative "#61 iOS suites green" signal is a filtered sim run (Session-D author reported `AppleAuthTests` 4/4 + `SettingsView` 5/5); CI can't serve as that signal until the snapshot refs are re-recorded (separate housekeeping).
**Execution status:** Sessions A–C (backend, 61.1–61.5) done + live (Fly v53); Session D (iOS) READY — gate cleared, not yet implemented.

## Why

Phase 1 (#60) fixes the freemium bypass on an anonymous identity. Phase 2 adds a **durable, recoverable real account**:

- Cross-device identity — a user can reinstall / switch iPhone and recover quiz history + premium by signing in again.
- IAP entitlements bind to `apple_sub`, which survives reinstall (the anchor #50 needs).
- Satisfies App Store Guideline 4.8 if a second login (Google, etc.) is ever added.
- Provides the mandatory in-app **Delete Account** (Guideline §5.1.1(v) + GDPR Art. 17) and **Export** (Art. 20).

**iOS-only MVP** (founder decision §8b #2): Sign in with Apple only; **email magic link deferred**. The self-issued-JWT token layer stays provider-agnostic so magic link is cheap to add later — do **not** adopt anything Apple-only at the token layer.

## Scope

**Backend (`apps/quiz-agent`):**
- New table: `users(id UUID PK, apple_sub TEXT UNIQUE NOT NULL, email TEXT NULL, apple_refresh_token_encrypted BYTEA NULL, created_at TIMESTAMPTZ NOT NULL)` — `plan_tier` dropped (F8, subscriptions deferred); `apple_refresh_token_encrypted` is encrypted at rest (F1/F2). **Coordinate schema with #50** so it satisfies IAP binding too (`apple_sub` is the anchor).
- `POST /api/v1/auth/apple`: verify the Apple identity token against Apple JWKS (`https://appleid.apple.com/auth/keys`, cache 24h), validate nonce, exchange `authorization_code` for an Apple refresh token (ES256 client_secret JWT, max expiry ~6 months / 15,777,000 s), upsert the user row, **merge the anonymous usage history** from `anon_id`→`users.id` per the F3 rule (sum counts, idempotent), return a server-issued JWT.
- `POST /api/v1/auth/refresh` — standard token refresh.
- `DELETE /api/v1/auth/me`: delete user row + usage + quiz history; call `https://appleid.apple.com/auth/revoke` with the **stored, encrypted** Apple refresh token (F1/F2 — decrypt to call; TN3194 no-token fallback if absent) — required by §5.1.1(v) + GDPR Art. 17 — "without undue delay", not a fixed 30 days; see §7. **Revoke is enforced in review — canonical reference is now Apple TN3194.**
- `GET /api/v1/auth/me/export`: GDPR Art. 20 export.
- Client-secret generation utility (PyJWT + `.p8`). **Key ID + Team ID + `.p8` + `APPLE_TOKEN_ENC_KEY` (Fernet key, F2) stored as Fly secrets.**

**iOS (`apps/ios-app`):**
- Add "Sign in with Apple" capability (Signing & Capabilities).
- `AuthService`: nonce generation (32 random bytes, SHA-256), `ASAuthorizationAppleIDProvider` credential flow, `getCredentialState` on cold launch, `credentialRevokedNotification` observer, anonymous→Apple upgrade request.
- In-app **Delete Account** UI in Settings (mandatory before submission) + **Export my data**.
- App Store privacy nutrition-label update.

## Resolved design decisions (plan review 2026-06-26)

Closes F1–F3 (blocking gaps) + the subscriptions/F8 call from the [plan review](../artifacts/issue-61-plan-review-2026-06-26.html). F4–F7 (edge-case decisions) and F9–F10 (notes) stay open there — listed under *Open / deferred*.

**F1 + F2 — Apple refresh-token storage & encryption at rest.**
One `apple_refresh_token_encrypted BYTEA NULL` column on `users` (1:1 with the user → a column, not a side table). The Apple refresh token is stored **encrypted with Fernet** (authenticated AES, from the `cryptography` lib already pulled in by `pyjwt[crypto]` — **no new dependency**). The key is a Fly secret `APPLE_TOKEN_ENC_KEY` (one `Fernet.generate_key()` value), never in the DB; decrypt only at `DELETE /auth/me` to call `/auth/revoke`. This deliberately contrasts with `refresh_tokens.token_hash`, which is SHA-256 *hashed* because it is only ever compared — the Apple token must be *recoverable*, so it is encrypted, not hashed. Nullable: if Apple returns no refresh token, fall back to the TN3194 no-token revoke path (don't block deletion).

**F3 — Anonymous → account merge rule (core Phase 2 correctness).**
On `POST /auth/apple`, in **one transaction**:
1. Resolve/insert the `users` row by `apple_sub`; get `users.id`.
2. Inspect the incoming `anon_id`'s `anonymous_identities.upgraded_to_user_id`:
   - already `== users.id` → **no-op** (idempotent retry), skip the merge;
   - set to a *different* user → reject (an anon identity upgrades to exactly one account);
   - unset → proceed.
3. For each `daily_usage` row keyed on `anon_id`, fold it into the user's row for the same `usage_date`: `questions_count` is **summed**, `is_premium` is **OR**ed (insert the user's row if absent).
4. Set `anonymous_identities.upgraded_to_user_id = users.id`.

**Sum, not max** — otherwise a user near the daily limit could sign out, burn a fresh anonymous bucket, and sign back in to "reset" the freemium limit. **Idempotency** comes from the `upgraded_to_user_id` flag (already in the #60 schema for exactly this): once set, re-calling `/auth/apple` for that `anon_id` is a no-op, so retries/double-submits never double-count. The user's canonical subject going forward is `users.id` (the access-token `sub`); the merged `anon_id`'s rows are left in place — harmless, since that `anon_id` is never the subject again and the flag blocks any re-merge.

**F8 — `plan_tier` dropped (subscriptions deferred, founder decision 2026-06-26).**
**No subscriptions in this release** (too much release complexity), but **wanted later**. So `plan_tier` is removed from the Phase 2 `users` schema — it modelled a subscription tier nothing builds yet (#50 is pack-purchasing only). Premium today stays on `daily_usage.is_premium`; the durable purchase anchor (`apple_sub`) remains, so the future subscription/entitlement model binds to it with no migration redo. Revisit when subscriptions are specced.

## Size & dependencies

**Size: M–L** — Apple client_secret generation + token revocation are the trickiest parts.
**Depends on:** #60 (auth middleware + `anon_id` must exist to merge).
**Also depends on / coordinate with #50** (StoreKit IAP binding): `apple_sub` is the purchase anchor — align the `users` schema with both.

## Tasks (atomic)

- [x] 61.1 — Alembic migration `0003` (down_revision `0002_app_attest` — current head): `users(id UUID PK, apple_sub TEXT UNIQUE NOT NULL, email TEXT NULL, full_name TEXT NULL, apple_refresh_token_encrypted BYTEA NULL, created_at TIMESTAMPTZ NOT NULL)` — `full_name` = **F5 resolved: store the Apple name** (founder 2026-06-27); **no `plan_tier`** (F8). Schema reviewed against #50 (pack-purchasing only, no schema of its own — `apple_sub` is a sufficient anchor; receipt binding is #62). **DONE 2026-06-27 (Session A)** — `alembic/versions/0003_users_table.py` + `User` in `app/db/models.py`; live up/down/up round-trip on a scratch DB + offline `--sql` guard (`tests/test_users_migration.py`).
- [x] 61.2 — Apple identity-token verifier (JWKS RS256, 24h cache, nonce validation). **DONE 2026-06-27 (Session A)** — `app/auth/apple.py` (`AppleIdentityVerifier`, `expected_nonce_claim`, `AppleVerificationError`); `tests/test_apple_verifier.py`. ⚠️ **Nonce = F6 (`base64url-nopad(sha256(raw_nonce))`) — iOS Session D MUST send this exact encoding, NOT hex** (the Session D prompt text says "hex"; that is wrong — see execution-prompts conflict note).
- [x] 61.3 — Apple client_secret generator (PyJWT + `.p8`); `.p8`/Key ID/Team ID **+ `APPLE_TOKEN_ENC_KEY`** (Fernet key, F2) as Fly secrets. **DONE 2026-06-27 (Session A)** — `app/auth/apple_secrets.py` (`generate_client_secret`, `AppleTokenCipher` + `build_apple_token_cipher`) + 5 optional env vars in `app/config.py`; `tests/test_apple_secrets.py`.
- [x] 61.4 — `POST /auth/apple`: authorization_code exchange → upsert user → **merge anon usage per F3** (one transaction, sum counts, OR premium, idempotent via `upgraded_to_user_id`) → **store encrypted Apple refresh token** (F1/F2) → issue JWT. ⚠️ **recon gotcha:** `daily_usage` is keyed on `subject_id` (= the JWT `sub`), **not** `anon_id` as the F3 text says — fold the anon's `subject_id` rows into `(users.id, usage_date)`. Returned JWT `sub` = `users.id`. **DONE 2026-06-27 (Session B)** — `app/api/routes/auth.py::apple_sign_in` + helpers, `AppleOAuthClient` (`app/auth/apple_oauth.py`), `TokenService.subject_from_token(allow_expired=)`, deps + `app.state` wiring (`tests/test_auth_apple_endpoint.py`, `tests/test_apple_oauth.py`). ⚠️ **Unplanned but required: migration `0004_refresh_subject`** drops the `refresh_tokens.anon_id → anonymous_identities` FK — Phase 1's FK would reject a `users.id`-subject refresh token, blocking the issue step; the merge also revokes the anon's live refresh tokens so the upgraded identity can't mint a fresh anon bucket. Commits `8bad2c7`/`e5f10ae`/`244f7e7`; 234 tests green (21 new), ruff clean, live migration round-trip OK.
- [x] 61.5 — `DELETE /auth/me`: explicit delete (no cascade after `0004`) + **decrypt stored Apple refresh token (F1/F2) → `/auth/revoke`** (best-effort F4; no-token *skip* when absent — `/auth/revoke` requires a token, so there is nothing to call); and `GET /auth/me/export` (GDPR Art. 20). **DONE 2026-06-27 (Session C)** — `app/api/routes/auth.py::delete_account`/`export_account` (+ `_resolve_account` authority rule, `_revoke_apple_grant` best-effort), `AppleOAuthClient.revoke()` in `app/auth/apple_oauth.py` (shared `_post` core; revoke skips the JSON parse since Apple answers an empty 200), `AccountExportResponse`/`AccountUsageRecord` in `app/api/deps.py`; `tests/test_auth_me_endpoints.py` (8 tests, real test Postgres + mocked `/auth/revoke`). The merged anon trail is **de-linked by nulling `upgraded_to_user_id`** (keeps the row's App Attest key binding intact, avoids the cascade — the unlinked row is a bare random id, not personal data). 242 tests green (8 new), ruff clean.
- [x] 61.6 — iOS Sign in with Apple capability + `AuthService` credential flow, nonce, credential-state/revocation observers, anon→Apple upgrade. **DONE 2026-06-30 (Session D, `16dcde3`)** — `applesignin` entitlement (both schemes); `AuthService.completeAppleSignIn` (request nonce = `base64url-nopad(SHA256(rawNonce.utf8))` per F6, **verified byte-for-byte against backend `expected_nonce_claim`**; POSTs with the current anon bearer so the backend merges; swaps stored tokens → account tokens, `sub`=`users.id`), `checkAppleCredentialState`/`setupAppleCredentialObservation` (cold-launch + `credentialRevokedNotification` → fresh anon), `signOut`/`deleteAccount`/`exportData`. `AppState` wires the observer at init. Token layer stays provider-agnostic.
- [x] 61.7 — iOS Settings: in-app Delete Account (with confirm) + Export. **DONE 2026-06-30 (Session D, `16dcde3`)** — `accountGroup` after audio-feedback / before about; signed-out (SIWA button), signed-in (name/email + Export my data + Sign out + Delete account, red), iOS confirm dialog (≤2 taps). Matches Pencil `taml6`/`JB9Oi`/`PmJ3A`. ⬜ **Privacy nutrition label is a `[HUMAN]` App Store Connect click-through (still pending).**
- [x] 61.8 — Tests: pytest for apple verify / merge / delete+revoke / export (Sessions A–C, mocked Apple); iOS unit tests for the credential flow (mocked). **DONE 2026-06-30** — `AppleAuthTests` (nonce F6 exact-transform, anon-bearer + token swap, delete clears+rebootstraps, revocation rebootstraps); build clean + AppleAuth 4/4 & SettingsView 5/5 green on the iOS 26.5 sim.

## Acceptance

- [ ] A user with anonymous usage signs in with Apple → their prior daily usage + history is **merged**, not lost.
- [ ] Sign-out → fresh anonymous bucket → sign back in **cannot** reset the freemium limit: same-day counts are summed, and a repeated `/auth/apple` for the same `anon_id` is idempotent (no double-count). *(F3)*
- [x] `DELETE /auth/me` removes all user data **and** revokes the Apple token (verified against a mocked `/auth/revoke`). *(Session C — backend; in-app UI is 61.7)*
- [x] `GET /auth/me/export` returns the user's data (Art. 20). *(Session C — backend; in-app UI is 61.7)*
- [ ] Reinstall + sign in recovers premium status (entitlement keyed to `apple_sub`).
- [x] In-app Delete Account is reachable in ≤2 taps from Settings and confirms before deleting. *(Session D — `accountGroup` → Delete account → confirm dialog.)*
- [ ] pytest + iOS unit suites green; **human security review** signed off (feeds #48 Stage 2).

## Open / deferred

- `.p8` rotation (6-month max): decide **who rotates** — Ralph (automatable Fly secret set) vs human-calendared. Resolve when this issue is specced (founder decision §8b #5).
- Supabase Auth (Frankfurt, 50k MAU free) remains the acknowledged escape hatch if self-managed auth ops get burdensome — not adopted now.
- **Subscriptions / `plan_tier`**: deferred (founder decision 2026-06-26 — not in this release, wanted later). Entitlement model designed when subscriptions are specced; `apple_sub` already provides the durable anchor. *(F8)*
- **Plan-review items F4–F7 — now resolved** (2026-06-27, see [`issue-61-execution-prompts.md`](issue-61-execution-prompts.md) *Locked decisions*): F4 = delete local immediately + best-effort revoke (retry/queue post-MVP); F5 = store `full_name`; F6 = nonce compare against `base64url-nopad(sha256(raw))`; F7 = `/auth/apple` deliberately **not** behind App Attest (valid Apple id_token suffices). F9 (Apple server-to-server notifications) stays Phase 3; F10 are implementation notes folded into the session prompts.

## Security review findings — 2026-07-03

Maker≠checker review of #60 + #61 auth (2 parallel reviewers: backend + iOS; load-bearing claims verified first-hand). Crypto core (JWT, refresh rotation/reuse-detection, Apple id_token verify, App Attest, Keychain, Fernet) — **solid, no findings**.

**Backend — all fixed in `a8434cb`, deployed to Fly 2026-07-03** (262 tests green, `/auth/logout` verified 204 on prod):
- [x] **B1 HIGH** — freemium daily-limit reset via sign-out/delete closed: merge keeps the anon's `daily_usage` rows frozen; `DELETE /auth/me` carries today's count back onto linked anons (GREATEST upsert). Fixed at the merge, not by rebinding the App Attest key (rebinding would brick re-bootstrap after account delete).
- [x] **B2** — new `POST /auth/logout` (body `{refresh_token}`, always 204 — idempotent, never reveals token validity, rate-limited) revokes the whole refresh-token family server-side.
- [x] **B3** — `/auth/refresh` rate-limited (20/min/IP) like sibling endpoints.
- [x] **B4** — re-attestation of an already-stored App Attest key (client crash-retry) re-issues the bound identity instead of 500-ing.
- [x] **B5** — concurrent first Apple sign-ins racing on `UNIQUE(apple_sub)` resolved via savepoint + re-read.

**iOS (`AuthService.swift` + `SettingsView.swift`) — all fixed 2026-07-03** (auth suites 16/16 green incl. 2 new I1 tests, verified first-hand):
- [x] **I1 HIGH** — `postTokens` treated any non-2xx as token-invalid → transient 5xx during a deploy silently orphaned a signed-in Apple account (fresh anon minted). Fixed: refresh outcome classified (401 = definitive rejection → re-bootstrap + `authSignedInSessionDropped` notification when Apple-linked; 5xx/timeout/offline = transient → tokens kept, retryable nil). 2 new tests encode both paths.
- [x] **I2 MED** — `signOut()` now calls `POST /auth/logout` (best-effort, failures ignored) before dropping to fresh anon, revoking the refresh-token family server-side.
- [x] **I3 MED** — Keychain save on the Apple sign-in path now verified by re-read; a persistence failure surfaces as sign-in failure instead of silently losing the account linkage on next launch.
- [x] **I4 MED** — `deleteAccount()`/`exportData()` route through a refreshing `sendAuthorized` helper (retry-once-on-401), no more routine 401 shown to user.
- [x] **I5 MED** — `accountErrorMessage` now rendered via an `.alert` in Settings.
- [x] **I6 LOW** — Delete-account row `.disabled(isDeletingAccount)`.
- [x] **I7 LOW** — account section reloads on the `authSignedInSessionDropped` notification (I5–I7 verified by clean build + green suites; no SettingsView unit tests exist).

**Accepted risk (documented, not fixed):** `require_auth` in `apps/quiz-agent/app/api/deps.py` returns `authenticated=False` instead of rejecting when `LEGACY_USER_ID_GRACE` is on — every current call site handles it, but the name invites misuse. Tracked in #65 (endpoint auth hardening), not churned here.

**GDPR note:** only *today's* counter is carried back on delete, without premium — fraud-prevention-minimal (GREATEST, can only tighten); full-history copy would retain account data past erasure.

## Cross-refs

- #58 (parent) · #60 (Phase 1 prerequisite) · #50 (IAP — `apple_sub` anchor; align schema) · #48 (security review) · #62 (Phase 3 cross-device + full binding).

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-48-pre-release-review-gauntlet|#48 Pre-release review gauntlet]] · [[issue-50-app-store-connect-setup|#50 App Store Connect listing + ASC API setup]] · [[issue-58-authentication|#58 Authentication]] · [[issue-60-auth-phase1-anonymous-identity|#60 Auth Phase 1]] · [[issue-62-auth-phase3-cross-device-purchase-binding|#62 Auth Phase 3]]
<!-- obsidian-links:end -->
