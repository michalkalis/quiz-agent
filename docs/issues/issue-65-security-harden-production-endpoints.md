# Issue #65 — Security: authenticate production endpoints (admin UI + AI cost routes + rate-limit IP)

**Triage:** security · done (follow-up closed 2026-07-06)

> **2026-07-06 (later): `LEGACY_USER_ID_GRACE=off` FLIPPED in prod** — founder confirmed prod has no real users (only him, latest build sends bearers), so no traffic-evidence wait was needed. Verified live: header-less `POST /api/v1/elevenlabs/token` → 401, header-less `POST /api/v1/sessions` → 401, health 200. **#65 fully closed.**

> **2026-07-06 re-scope (founder decisions #5 + #6, 2026-07-05).** The grace-mode pass-through is no longer *silent*: every unauthenticated pass logs a `AUTH GRACE` WARNING with the route (`app/auth/identity.py`), production boot logs a `SECURITY` error while `LEGACY_USER_ID_GRACE` is on (`startup_checks.py`), and the misuse-inviting `require_auth` dependency was renamed `require_auth_or_grace` (identity: `require_bearer_or_grace`) with the not-a-hard-gate contract documented — closes the accepted-risk item from the 2026-07-03 review. Deployed to Fly.
>
> **Remaining step — flip `LEGACY_USER_ID_GRACE=off`** once evidence shows no live client depends on it: watch prod logs for `AUTH GRACE` lines (now countable). Latest TestFlight build (2026-07-03, `0c8dab0`) sends bearers; older installs would break on flip. Flip = `fly secrets set LEGACY_USER_ID_GRACE=off -a quiz-agent-api`; verify header-less `POST /api/v1/elevenlabs/token` → 401.
>
> **Bonus finding fixed same session:** prod ran with `ENVIRONMENT` unset, so *every* production-only startup SECURITY check (incl. the original #65 App Attest warnings) was silently skipped and Sentry labeled prod "development". `fly.toml` now sets `ENVIRONMENT=production`; verified the SECURITY boot log fires live.

**Note (2026-07-06):** verified 2026-07-06: `routes.py:24` has router-wide `require_admin`, quiz-agent voice/tts/misc endpoints under `require_auth`.

**Created:** 2026-06-21 · **Founder:** Michal · **Source:** #64 full-project review (rank 1, 2, 7, 9 — all verified first-hand)

**Severity:** critical — exploitable on live Fly URLs today.

## Problem

Three authentication/rate-limit gaps are live on public Fly.io URLs:

1. **quiz-pack-api admin UI + generation endpoints are completely unauthenticated.** Anyone on the internet can approve/reject/import questions or trigger paid `gpt-4o` generation.
2. **quiz-agent high-cost AI endpoints have no bearer-token check** (Whisper transcribe, voice submit, TTS synth, question audio). The **ElevenLabs single-use-token endpoint has neither auth nor a rate limit** — any caller can mint real ElevenLabs realtime tokens and drain the budget.
3. **All non-auth rate limiters key on the Fly proxy IP**, so every per-client limit is actually one shared global bucket.

A fourth, related gate: **App Attest is inert by default** (`app_attest_required=False`), so the whole #60 App Attest investment ships off unless a Fly secret is set.

## Evidence (verified first-hand 2026-06-21)

- `apps/quiz-pack-api/app/web/routes.py` — zero auth `Depends()` across all routes (only a `# TODO: Get from auth` at line 195). `app/main.py:75` mounts `web_router` unconditionally; `main.py:66` sets CORS `allow_origins=["*"]`.
- `apps/quiz-agent/app/api/routes/voice.py:28-29,66-67` and `tts.py:25-26,50-51` — the only `Depends()` are **service injection** (`get_voice_transcriber`, `get_session_manager`, …), no auth/subject resolution.
- `apps/quiz-agent/app/api/routes/misc.py:16-17` — `POST /elevenlabs/token` has **no `@limiter.limit` and no auth**.
- `apps/quiz-agent/app/rate_limit.py:10` — `limiter = Limiter(key_func=get_remote_address)`. `fly_client_ip` exists (lines 13-21) but is used only at `auth.py:52,182`.
- `apps/quiz-agent/app/config.py:34` — `app_attest_required: bool = False` (env default `"false"`).
- Confirmed-OK (do not change): `misc.py:67 set_premium` already checks `X-Admin-Key` against `ADMIN_API_KEY`.

## Recommendation

- **quiz-pack-api:** add an `ADMIN_API_KEY` `Depends` guard to all `/web/*` and `/api/v1/generate*` / `/api/v1/verify` / review-submit routes. Reuse the `X-Admin-Key` pattern already in `quiz-agent/app/api/routes/misc.py:67` (or `app/api/admin.py`). Add `@limiter.limit("10/minute")` to generation routes. Lock CORS to known origins in prod.
- **quiz-agent:** add a token-only `Depends` (`resolve_session_subject` or a lightweight optional-subject) to `voice.py`, `tts.py`, and the ElevenLabs token route; add `@limiter.limit("10/minute")` to `POST /elevenlabs/token`.
- **rate-limit fix:** change `rate_limit.py:10` to `Limiter(key_func=fly_client_ip)` — one line fixes every existing decorator. (⚠️ `Fly-Client-IP` is only trustworthy because Fly strips client-supplied copies at the edge — confirm at deploy; documented as R-2 in #60.)
- **App Attest guard:** in `main.py` startup, if `ENVIRONMENT == "production"` and not `app_attest_required`, log a loud error; and keep `APP_ATTEST_REQUIRED=on` + `APP_ATTEST_APP_ID` as a hard gate in the #60 pre-prod checklist.

## Acceptance

- [x] `GET /web/` and `POST /api/v1/generate/advanced` on quiz-pack-api return 401/403 without a valid admin key — `require_admin` dep gates both routers; `tests/api/test_admin_auth.py` (7 tests, green)
- [x] `POST /api/v1/voice/transcribe` and `POST /api/v1/elevenlabs/token` on quiz-agent return 401 without a valid bearer token — `require_auth` dep (bearer-or-grace) on voice transcribe/submit, TTS synth/question/session-feedback-audio, and elevenlabs/token; `tests/test_require_auth.py` (5) + `tests/test_misc_elevenlabs_auth.py` (4), green
- [x] `POST /api/v1/elevenlabs/token` is rate-limited to ≤10/min per client IP — `@limiter.limit("10/minute")`; `test_misc_elevenlabs_auth.py::test_rate_limited_to_10_per_minute` (11th call → 429)
- [x] Two requests with different `Fly-Client-IP` values get independent rate-limit counters (regression test) — limiter re-keyed on `fly_client_ip` (real client IP, not Fly proxy); `tests/test_rate_limit_key.py` (5 tests, green)
- [x] Production startup logs a loud error (or refuses) when `app_attest_required` is false in prod — `warn_if_insecure_production` (called in `main.py` lifespan) logs a `SECURITY` error; `tests/test_startup_checks.py` (4 new tests, green). Warns, does not refuse.
- [x] Backend test suites stay green — quiz-agent: 179 passed. quiz-pack-api: admin-auth + rate-limit suites green; 4 failed / 10 errored are **pre-existing and unrelated** to #65 (3× orders 200-vs-202 status mismatch, verified identical with my changes stashed; 1 alembic-idempotent + 10 alembic schema-already-exists fixture errors).

## Decisions (founder delegated all three to me, 2026-06-22)

1. **Admin-UI auth carriers → keep both.** `X-Admin-Key` header (scripts/agents) + HTTP Basic (so `/web` opens with a browser password prompt). The key is the only secret either way.
2. **quiz-pack-api generation rate-limit → added now** (founder: "limiting makes sense"). slowapi added to quiz-pack-api (pyproject + Dockerfile, dep-drift rule); `app/rate_limit.py` mirrors quiz-agent (keyed on `fly_client_ip`); `@limiter.limit("10/minute")` on the four billable routes — `/generate`, `/generate/advanced`, `/verify`, `/verify/batch`. The cheap CRUD/review routes stay unlimited. `tests/api/test_generation_rate_limit.py` (2 tests, green).
3. **Unset `ADMIN_API_KEY` → fail-closed everywhere** (503 in dev and prod alike). No env-dependent security branch; set a dev key locally to use the admin UI.

## Deploy gate (NOT yet deployed — founder triggers)

1. Set `ADMIN_API_KEY` Fly secret on quiz-pack-api **before** deploy — without it `/web` + `/api/v1` return 503 everywhere (by design).
2. Set `CORS_ORIGINS` on quiz-pack-api — defaults to `localhost:3000`, so the prod web-ui origin is blocked until set.
3. Confirm `Fly-Client-IP` is edge-stripped by Fly (R-2 in #60) — the rate-limit key trusts it.
4. Leave `LEGACY_USER_ID_GRACE=on` until #60 iOS auth is on TestFlight — the quiz-agent gate passes header-less requests during grace, so deploying now does not break the pre-auth build.

## Deployed & verified in prod (2026-06-22)

Both apps deployed by founder. `ADMIN_API_KEY` set on quiz-pack-api beforehand.

- **quiz-pack-api** — `GET /web/` → 401 without key, `/health` → 200. Admin auth + generation rate-limit live.
- **quiz-agent-api** — initial deploy **crash-looped** (`ModuleNotFoundError: No module named 'jwt'`): the #60/#61 auth modules are imported at boot via `app/api/deps.py` but the hand-maintained Dockerfile pip list predated the auth phase and lacked `sqlalchemy`/`asyncpg`/`alembic`/`pyjwt`/`pyattest` (this deploy was the **first** to ship the auth code to prod). Fixed in commit `4ed9910` (Dockerfile now 1:1 with pyproject + drift-guard comment), redeployed → healthy.
- **Auth gate verified live:** invalid bearer → 503 (fail-closed reject, not passed); header-less → 200/422 (grace-passes by design while `LEGACY_USER_ID_GRACE` on). Rate limit verified: 10 `elevenlabs/token`/min/IP then 429.

### Residual items (not blocking, tracked)
- **`elevenlabs/token` is still mintable without a token while grace is on** — now bounded to 10/min/IP (drain fixed from global to per-client), but full auth lockdown only activates when grace flips off (gated on #60 iOS auth reaching TestFlight).
- **Set the access-token signing secret on quiz-agent-api before flipping grace off** — currently unset, so any presented bearer fails to 503; harmless now (no clients send tokens), blocking once iOS auth ships.
- **`require_auth` returns `authenticated=False` instead of rejecting while `LEGACY_USER_ID_GRACE` is on** (`apps/quiz-agent/app/api/deps.py`) — accepted risk from the 2026-07-03 auth security review (#60/#61): every current call site handles the flag, but the name invites misuse by a future call site that assumes it rejects. Address when grace flips off (rename or make it reject).
