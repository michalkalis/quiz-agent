# Issue #65 — Security: authenticate production endpoints (admin UI + AI cost routes + rate-limit IP)

**Triage:** security · ready-for-agent

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
- [x] Backend test suites stay green — quiz-agent: 179 passed. quiz-pack-api: admin-auth suite green (3 pre-existing alembic-fixture errors unrelated to #65)
