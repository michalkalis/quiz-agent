# Backend Architecture Review — 2026-07-18

Scope: `apps/quiz-agent`, `apps/quiz-pack-api`, `packages/shared`, alembic/data layer, Fly environments, API contract, reliability/observability, testability, auth/money. 9 dimensions, every finding adversarially verified (3 refuted claims already removed).

## TL;DR

The backend is architecturally sound: layering is acyclic and thin-routed, the auth/money core (JWT single-source, StoreKit JWS chain validation, watermark-ordered subscription state, advisory-lock-serialized money writes) is unusually mature for a pre-MVP solo project, and the #101 prod/staging separation is real, not cosmetic. The weaknesses are concentrated at the edges, not the core: one latent money misconfig (prod StoreKit verifier defaults to Sandbox), a CI hole that silently skips all 13 DB-backed money/auth test suites, zero observability on the billable pack service, and the app's busiest payload (Question) living outside the OpenAPI contract. The env setup is sensible and fails closed on the RC ingest path, but has parity drift (staging missing SIWA secrets, prod memory not codified, opposite DB topologies per env). Nothing found corrupts money state silently; the four highs are all cheap to fix.

**Counts:** 9 dimensions · 21 confirmed findings after de-dup (**4 high · 16 medium · 1 low**) · 17 unverified (2 medium, 15 low).

## Environments: staging vs prod

**Well set up (verified live via flyctl):**
- Clean per-service prod/staging app split (`quiz-agent-api[-staging]`, `quiz-pack-api[-staging]`) with separate `DATABASE_URL` (staging), separate `REVENUECAT_WEBHOOK_SECRET`, and distinct `AUTH_JWT_SECRET` per env — real isolation, verified by secret digests.
- RC money ingest fails closed: `RC_ALLOWED_ENVIRONMENT` unset/invalid → entitlements refused; prod=PRODUCTION / staging=SANDBOX confirmed as distinct secrets.
- Shared prod Postgres handled safely: quiz-agent uses dedicated `alembic_version_quiz_agent` version table; table sets are disjoint; a regression test asserts the isolation.
- Self-hosted `quiz-pack-redis` is private-network only, envs separated by logical DB index (prod 0 / staging 1). All six apps pinned to `cdg`; `auto_stop` + `min_machines_running=0` is correct cost hygiene; Dockerfile pip lists match pyproject boot deps.

**Asymmetric / wrong:**
- **HIGH:** prod `quiz-pack-api` has no `STOREKIT_ENVIRONMENT` secret → JWS verifier defaults to `"Sandbox"` and would reject real App Store Production pack purchases ("environment mismatch"). Latent only because there are no real users; staging has the secret, prod doesn't.
- Prod quiz-agent runs 512MB set only via out-of-band `fly scale`; staging pins `[[vm]] memory="512mb"` in toml (with a comment that 256MB fails the boot health check). A prod reprovision falls back to the failing default.
- Staging quiz-agent lacks all `APPLE_SIGNIN_*`, `APPLE_TOKEN_ENC_KEY`, `CORS_ORIGINS` secrets present on prod — the /auth/apple flow is untestable pre-prod; #101's own parity table lists CORS_ORIGINS and simply omits SIWA.
- `quiz-pack-api` has no Sentry in any environment (no DSN secret, no `sentry_sdk` in code) while quiz-agent inits Sentry in both envs.
- Topology mismatch: prod shares one `DATABASE_URL` across both services (same digest) while staging splits them — safe today, but staging doesn't reproduce prod's shared-DB behavior (unverified/low).
- Minor drift: staging pack-api runs 2 web machines vs prod's 1; `ENVIRONMENT` var set in pack staging toml but never read by pack code; prod quiz-agent carries a dead `ADMIN_KEY` beside the read `ADMIN_API_KEY` (unverified/low).

## Per-dimension assessments

**Layering — quiz-agent.** Sound and acyclic: routes → domain services → db/shared with zero upward imports, services built once in lifespan and injected via one-line `Depends` getters with documented graceful degradation. `subscription_state.py` is an exemplary pure-logic module (single home for all entitlement math), and `QuizFlowService` cleanly deduplicates the /input vs /voice answer flow. The two real debts: `auth.py` is an 874-line route God module holding transactional domain logic, and session state is structurally single-machine (in-memory dict + per-machine SQLite volume).

**Layering — quiz-pack-api.** The Stage pipeline (PackGenerator + Stage Protocol + OrderContext) is a clean, uniform contract a principal engineer would pass; API/worker code sharing is factored right (collaborators built once in worker startup, `tasks.py` owning only worker concerns), and the SSE bridge has genuinely correct reconnect semantics (step-log replay + event-id dedup across the replay/subscribe race). The issues are at the edges: one deployable hosts two products (legacy admin curation tool + live order service) with two URL conventions and stale service metadata. Notably, `storekit/` correctly belongs here — this service fulfills the consumable purchase.

**Shared package & duplication.** `quiz_shared` is cohesive, not a dumping ground: the Question model, LLM factory, and pgvector store are genuinely dual-consumer with zero import-direction violations, and the `auth/tokens.py` promotion (shared implementation, thin per-app re-export) is the model pattern. The gap is infra that was *not* promoted the same way: `normalize_async_url` (the prod-critical asyncpg `sslmode`→`ssl` gotcha) and `fly_client_ip` are copy-pasted into both apps, and the two apps use contradictory config idioms that independently redeclare the cross-service JWT issuer/audience contract.

**Data layer.** Deliberately architected and correct on the hardest constraint — two Alembic histories on one physical cluster, with version-table isolation backed by an intent-encoding regression test. The sslmode→ssl normalization and forward-only migration policy are properly root-caused and documented; the past identity-map flake was fixed in the right layer (test harness only). Both gaps are missing safety rails, not motion defects: autogenerate can propose DROPping the co-tenant's tables (no `include_object` filter), and migrations are hand-run with no deploy gate or boot-time head check.

**Environments.** See dedicated section above. Verdict: #101 executed mostly well, money-ingest hardened and fails closed; one high-severity latent misconfig (StoreKit env) plus codification/parity drift.

**API contract.** The Pydantic → OpenAPI → iOS Codable pattern with `/verify-api` is sound and well-executed for auth, sessions, entitlements, and the fully-typed orders flow; the RC webhook contract has a precise fail-closed status taxonomy, and `scripts/export_openapi.py` diffs schemas cheaply without booting the TTS lifespan. The weak seam is exactly the payload iOS renders most: the Question goes out as a hand-built untyped dict, invisible to OpenAPI and structurally uncoverable by verify-api.

**Reliability & observability.** quiz-agent is the mature half: Sentry init, JSON logging, fail-loud boot on missing critical secrets, all external HTTP bounded at 10s, idempotent RC webhook writes keyed on `rc_event_id`, and a well-engineered stuck-order sweep (row locks + shared retry budget). The dominant weakness is that the billable pack service and its arq worker have no Sentry and no structured logging at all; secondary: OpenAI/LLM calls on the driving hot path inherit the SDK's 600s default timeout while everything else is bounded, and the health check gating Fly rollback verifies nothing.

**Testability.** Test *content* is principal-grade: two-connection deterministic TOCTOU tests for double-spend and refund-guard races, airtight pack-api hermeticity (LLM_GATEWAY pinned pre-.env + respx `assert_all_mocked` egress guard), and a thorough StoreKit JWS security suite with positive controls. The *architecture* has one serious hole — quiz-agent CI provisions no Postgres, so all 13 DB-backed money/auth suites silently skip and CI stays green — plus divergent DB-fixture strategies between the apps and untested paywall-trigger responses.

**Auth & money architecture.** Unusually mature: single-source token authority with pinned algorithm allowlists everywhere, defense-grade JWS chain validation (RFC 5280 CA/pathLen + Apple marker OIDs), pure watermark-ordered subscription state, RFC 9700 refresh rotation with family reuse detection, and default-deny on null subjects with the 404-not-403 pack IDOR guard. The one confirmed blemish (admin `set_premium` writing a dead column) was verified to be known, documented #93 cleanup debt, downgraded to low. The pragmatic-but-uncontracted seam is quiz-agent reading quiz-pack-api's `question_packs` via raw SQL.

## Confirmed findings

### High

- **[HIGH] Prod StoreKit verifier defaults to Sandbox — rejects real purchases** — `apps/quiz-pack-api/app/config.py:43` (env dimension)
  Prod `quiz-pack-api` has no `STOREKIT_ENVIRONMENT` secret (re-verified live 2026-07-18: staging has it, prod doesn't), so the JWS verifier (storekit/verifier.py:137) rejects App Store Production transactions with "environment mismatch"; latent until GA since TestFlight = Sandbox. Fix: `fly secrets set STOREKIT_ENVIRONMENT=Production -a quiz-pack-api` and make the default fail-closed/None like `RC_ALLOWED_ENVIRONMENT`. Timing: after the flip, TestFlight pack-purchase tests against prod will be rejected (TF is always Sandbox) — TF purchase testing then belongs on staging, which is already the #101 beta→staging intent.

- **[HIGH] Core Question payload is an untyped dict, invisible to OpenAPI/verify-api** — `apps/quiz-agent/app/serializers.py:14` (api-contract)
  The most-rendered payload is a hand-built dict (`Dict[str, Any]` on InputResponse, bare-dict /question route), so iOS hand-mirrors it and optional-field drift fails silently at runtime, outside verify-api's reach. Fix: define a `PublicQuestion` Pydantic model (Question minus `correct_answer`) in quiz_shared and use it as `response_model` on both routes.

- **[HIGH] quiz-pack-api has zero Sentry and no structured logging in any env** — `apps/quiz-pack-api/app/main.py:1` (reliability) + env dimension (no `SENTRY_DSN` on prod or staging)
  The billable order/generation service and its arq worker report nothing to Sentry and log unstructured stdout — refund-eligible pipeline failures are invisible. Fix: mirror quiz-agent's DSN-gated `sentry_sdk.init` in main.py AND worker `on_startup` (separate process), reuse the shared JSON logging, set `SENTRY_DSN` on both envs. (Re-verified live 2026-07-18: quiz-agent has `SENTRY_DSN` on both prod and staging; both quiz-pack-api apps have none.)

- **[HIGH] quiz-agent CI runs no DB — all 13 money/auth suites silently skip** — `.github/workflows/backend-ci.yml:50` (testability)
  The test-backend job has no Postgres service and no `TEST_DATABASE_URL`, so `conftest.py:41` skips test_webhooks, test_entitlement, test_usage_tracker and the entire auth suite while CI goes green. Fix: add a pgvector Postgres service + `TEST_DATABASE_URL` (mirroring the quiz-pack-api job) and fail loud if the money suites collect zero non-skipped tests.

### Medium

- **[MED] auth.py route is an 874-line God module with transactional domain logic** — `apps/quiz-agent/app/api/routes/auth.py:506` (layering-qa)
  Identity merge, usage summing, subscription/credit folding, and Apple-grant revocation live as raw SQLAlchemy in the HTTP layer (~3x the 300-line rule), while the parallel webhook-side writes correctly live in `usage/rc_service.py`. Fix: extract the DB-touching helpers into an auth/usage domain service (sibling to rc_service), leave the route as orchestration.

- **[MED] Session state is structurally single-machine** — `apps/quiz-agent/app/session/manager.py:37` (layering-qa)
  In-memory dict write-through to per-machine SQLite on a single Fly volume; a second machine (auto_start is on, no affinity) 404s mid-session. Fix: document the single-machine constraint now; move sessions to the existing Postgres (or Redis) before scaling >1 machine.

- **[MED] JWS verify-cache misfiled under the SSE package** — `apps/quiz-pack-api/app/sse/jws_cache.py:1` (layering-pack)
  Pure StoreKit JWS verify caching (imports only from `..storekit`) lives in `sse/` — misleads any grep for either concern. Fix: move to `app/storekit/jws_cache.py` (one file, one import site).

- **[MED] Service metadata describes only the legacy half; two version conventions** — `apps/quiz-pack-api/app/main.py:59` (layering-pack)
  Title/description/root endpoint map still say "Quiz Question Generator", omit `/v1/orders` entirely, and advertise port 8001 (actual: 8003). Fix: update title/root map to lead with orders, fix 8001→8003, unify the version prefix during legacy cleanup.

- **[MED] `normalize_async_url` + engine build duplicated verbatim in both apps** — `apps/quiz-pack-api/app/db/engine.py:10` + `apps/quiz-agent/app/db/engine.py:20` (shared; also flagged by data-layer) *(adjusted)*
  The prod-critical sslmode→ssl gotcha is copy-pasted and already diverging: quiz-agent fails loud (RuntimeError) on missing DATABASE_URL while pack silently falls back to a local-dev default and fails later, unclearly (verifier: the claimed AttributeError-on-None cannot occur — pydantic guarantees a string). Fix: promote `normalize_async_url` (+ a build_engine helper) into `quiz_shared.database`, exactly like the tokens.py precedent.

- **[MED] Two contradictory config idioms; JWT identity contract redeclared in both apps** — `apps/quiz-agent/app/config.py:53` (shared)
  Hand-rolled dataclass + os.getenv (quiz-agent) vs pydantic-settings + lru_cache (pack), and the cross-service `auth_jwt_issuer`/`audience` literals are independently hardcoded in both — never set as Fly secrets, no test enforces the match, so one edited default silently breaks cross-service token verification. Fix: converge on pydantic-settings and hoist the JWT identity defaults into one shared constant.

- **[MED] Autogenerate can DROP the other app's tables** — `apps/quiz-agent/alembic/env.py:41` (+ pack env.py:43) (data-layer)
  Both env.py files target only their own metadata with no `include_object` filter against the shared cluster, so `alembic revision --autogenerate` emits `drop_table` for the co-tenant's tables. Fix: add an `include_object` allowlist hook to each env.

- **[MED] Migrations are manual — no deploy gate, no boot-time head check** — `apps/quiz-agent/app/startup_checks.py:13` (data-layer)
  No `release_command` in any fly.toml (Dockerfile ships alembic "for running via fly ssh console"); a deploy can ship code against an unmigrated schema and fail at runtime, contradicting the fail-loud rule — and this class of gap has bitten prod before (#60). Fix: boot-time assertion that the DB version table matches script head, or a `release_command` running `alembic upgrade head`.

- **[MED] Prod quiz-agent memory (512MB) not codified in fly.toml** — `apps/quiz-agent/fly.toml:1` (env)
  Live size exists only in `fly scale`; a reprovision falls back to 256MB, which staging's own comment says fails the boot health check. Fix: add the same `[[vm]] memory = "512mb"` block staging already has.

- **[MED] Staging missing Sign-in-with-Apple + CORS secrets present on prod** — `apps/quiz-agent/fly.staging.toml:1` (env)
  All `APPLE_SIGNIN_*`, `APPLE_TOKEN_ENC_KEY`, `CORS_ORIGINS` absent on staging (verified live) — /auth/apple boots gracefully disabled (503), so the auth surface can only regress in prod; #101's parity table lists CORS_ORIGINS but omits SIWA entirely. Fix: mirror sandbox-safe values onto staging, or explicitly document SIWA as prod-only.

- **[MED] quiz-pack-api mixes /api/v1 and /v1 URL prefixes** — `apps/quiz-pack-api/app/api/v1/orders.py:60` (api-contract)
  Questions/admin at `/api/v1`, orders at `/v1/orders`, web at `/web` — no single base path, undocumented, hard-coded per-endpoint on iOS; quiz-agent is uniformly `/api/v1`. Fix: align orders to `/api/v1/orders` or document the split as deliberate.

- **[MED] No timeout on OpenAI/LLM calls on the voice hot path** — `packages/shared/quiz_shared/llm/factory.py:138` (reliability)
  `openai_client()` passes no `timeout=`, so TTS/Whisper/translation/evaluation inherit the SDK's 600s default while every httpx call is bounded at 10s — the latency-critical driving path is the only unbounded one. Fix: pass an explicit `httpx.Timeout` (~15-30s read cap) in the shared factory.

- **[MED] Health check gating Fly rollback verifies no dependencies** — `apps/quiz-agent/app/api/routes/misc.py:128` (reliability)
  `/api/v1/health` returns a static dict; a deploy against an unreachable DB passes the rollback gate (the repo already has a DB-probing health monitor — wired to the wrong route). Fix: cheap `SELECT 1` in the checked endpoint, 503 on failure.

- **[MED] Divergent DB-fixture strategies; quiz-agent never exercises migrations** — `apps/quiz-agent/tests/conftest.py:44` (testability)
  quiz-agent tests build schema from `Base.metadata.create_all` (model/migration drift invisible; revisions 0001/0002/0005-money/0006 untouched by any test) while pack-api uses an alembic-migrated DB. Fix: run `alembic upgrade head` against quiz-agent's test DB, or add a create_all-vs-migrated drift assertion.

- **[MED] No response-level test for the paywall trigger** — `apps/quiz-agent/app/api/routes/quiz.py:64` (testability)
  The 429 `quota_limit_reached` payload and `usage_limit_error` branch — the exact contract iOS keys the paywall on — have zero assertions; the closest suite stubs `check_limit` to always allow. Fix: one DB-backed test exhausting free+credits asserting the 429 body, `usage_limit_error` shape, and that `record_question` is NOT called on deny.

- **[MED] pack-api tests share one persistent DB with no per-test isolation** — `apps/quiz-pack-api/tests/conftest.py:54` (testability)
  Isolation relies on per-author unique IDs (this exact fragility already caused the order-e2e CI flake, 154b95b); a TRUNCATE fixture exists in tests/api but isn't applied to tests/db or integration. Fix: rollback-on-teardown transaction wrapper or TRUNCATE fixture suite-wide.

### Low

- **[LOW] Admin `set_premium` writes a column the quota gate no longer reads** — `apps/quiz-agent/app/api/routes/misc.py:98` (auth-money) *(adjusted: downgraded from medium)*
  Known, documented #93 cleanup debt: the admin-only endpoint writes `daily_usage.is_premium`, which `check_limit` ignores post-#93; the sole client caller was already retired, so only a manual admin curl can hit the display/enforcement divergence. Fix: file as routine cleanup — retire the endpoint/column or wire it to a real subscription/credit grant.

## Unverified findings (not adversarially verified)

**Medium:**
- In-memory slowapi rate limiter → per-machine limits if Fly scales out; quiz-agent's are a security control on unauthenticated identity minting — `apps/quiz-agent/app/rate_limit.py:30`
- Order delivery is a non-atomic two-phase commit: pack persist and "delivered" status commit separately (with an external HTTP call between), so a worker crash re-runs the full paid pipeline and double-generates — `apps/quiz-pack-api/app/worker/tasks.py:145`

**Low:**
- `deps.py` is a 465-line catch-all mixing every route's Pydantic schemas with DI getters — `apps/quiz-agent/app/api/deps.py:36`
- `admin.py` route module sits in `app/api/` while all other routes live in `app/api/routes/` — `apps/quiz-agent/app/api/admin.py:24`
- Legacy admin half instantiates LLM singletons at module import, even on the order-only path (README's deferred Phase-6 cleanup) — `apps/quiz-pack-api/app/api/routes.py:45`
- `fly_client_ip` rate-limit key duplicated verbatim in both apps — `apps/quiz-pack-api/app/rate_limit.py:14`
- `sql_client` (495 lines) and `pending_store` each have exactly one app consumer yet live in shared — `packages/shared/quiz_shared/database/sql_client.py:1`
- pgvector hand-mirrored `questions` Table can silently drift from the ORM schema on upserts; add a parity test — `packages/shared/quiz_shared/database/pgvector_client.py:60`
- No connection-pool budget (max_overflow unset) documented vs the shared 1GB cluster's max_connections — `apps/quiz-pack-api/app/db/engine.py:41`
- Prod shares one DATABASE_URL across services, staging splits them — topology mismatch — `apps/quiz-agent/alembic/env.py:51`
- Env-parity drift: staging pack web=2 vs prod=1; inert `ENVIRONMENT` var; dead `ADMIN_KEY` secret — `apps/quiz-pack-api/fly.staging.toml:15`
- Three different ack/success envelope shapes across mutation routes, none with response_model — `apps/quiz-agent/app/api/routes/quiz.py:300`
- Cross-service play-a-pack seam: quiz-agent raw-SQL-reads pack-api's `question_packs` (id, user_id) with no shared model/contract — a pack-api migration silently breaks quiz-agent's ownership+quota gate — `apps/quiz-agent/app/api/routes/sessions.py:56` (flagged by both api-contract and auth-money)
- Tavily failures swallowed via `print()` in a bare except, client has no timeout — `apps/quiz-pack-api/app/sourcing/web_search_source.py:80`
- TTS service + cache (core voice hot path) have no dedicated test — `apps/quiz-agent/app/tts/service.py:1`
- TOCTOU interleave tests use fixed `asyncio.sleep(0.3)` as the race barrier — flake/false-pass risk on loaded runners — `apps/quiz-agent/tests/test_entitlement.py:286`
- `LEGACY_USER_ID_GRACE` defaults on: bearer-less requests still trust body `user_id` as quota subject — flip off in prod once grace-passthrough WARNINGs read zero — `apps/quiz-agent/app/auth/identity.py:133`

## Remediation — 2026-07-20

Run: dynamic workflow `wf_b215d380-fb3` (11 agents: baseline → 6 file-disjoint fix groups → verify loop → adversarial review → gap-fix round) in worktree `backend-arch-review`. **All 21 confirmed findings closed or explicitly dispositioned.** Suites green: quiz-agent 426 · quiz-pack-api 645 · shared 7, ruff clean. Independent adversarial review verified the high-risk seams first-hand: Question wire-compat pinned by literal-dict tests for all 5 types (`correct_answer` structurally absent), `/v1/orders` still serves identically beside canonical `/api/v1/orders`, StoreKit fail-closed refuses at verify-time (no boot crash), auth extraction AST-compared verbatim, boot head-check passes when DB is ahead and skips without `DATABASE_URL`.

**Fixed in code (per finding):** Sentry + JSON logging in quiz-pack-api API **and** arq worker (new `logging_config.py`, DSN-gated; sentry-sdk added to pyproject + Dockerfile pip list) · `storekit_environment` fail-closed (default None + validator; verifier refuses when unset) · CI pgvector Postgres + `TEST_DATABASE_URL` + `REQUIRE_DB_TESTS=1` fail-loud (the 13 DB money/auth suites now gate merges) · `PublicQuestion` typed contract in quiz_shared, `response_model` on the question route + typed `InputResponse.question` · auth.py 875→410 lines, transactional logic moved verbatim to `usage/account_merge.py` + `auth/account_service.py` · alembic `include_object` allowlists in both envs (autogenerate can no longer DROP co-tenant tables — proven on scratch DB) · fail-loud boot-time migration head check, NO auto-migrate, wired in quiz-agent lifespan + pack lifespan + pack worker · jws_cache moved to `storekit/` · pack service metadata/port/version fixed · `/api/v1/orders` canonical + deprecated `/v1/orders` alias for deployed iOS clients · shared promotions (`normalize_async_url`/engine, JWT issuer/audience constants with intent tests in both apps, `fly_client_ip`) · quiz-agent config converged to pydantic-settings · LLM factory default timeout 30s hot path / explicit 300s generation override at pack call sites · health endpoint probes DB (SELECT 1, 3s cap, 503) · migration-drift guard test (non-vacuous, verified against a planted column) · paywall 429 contract test (exhausts free+credits, asserts body shape + `record_question` not called on deny) · pack suite-wide TRUNCATE isolation (fresh-DB twice-green preserved) · Tavily logger + narrowed except + 10s timeout · `set_premium` admin endpoint retired (dead post-#93 column documented in the model).

**Env/secrets (verified live 2026-07-20):** `SENTRY_DSN` present on all four apps (same digest). Prod pack `STOREKIT_ENVIRONMENT` present, digest-equal to staging = **Sandbox — founder call 2026-07-20: TestFlight/sandbox pack purchases stay working on prod; flip to `Production` is a GA-launch step** (one `fly secrets set`). `CORS_ORIGINS` set on quiz-agent staging 2026-07-20. Still owed: staging `APPLE_SIGNIN_*` + fresh `APPLE_TOKEN_ENC_KEY` (founder-held .p8; exact command in issue #101 — prod/sandbox environment separation, §3.5).

**Unverified-findings dispositions:** slowapi per-machine rate limits — real, documented as a scaling constraint (single-machine today) · **two-phase order delivery — CONFIRMED real** (crash between pack persist and delivered-commit re-runs the paid pipeline → double generation; proper fix = idempotent PersistStage keyed on order_id; seam commented in `worker/tasks.py`, follow-up filed on TODO) · Tavily + `fly_client_ip` fixed (above) · remaining 10 lows deferred/accepted with recorded reasons (deps.py split, admin.py placement, legacy import-time LLM singletons, sql_client/pending_store placement, pgvector parity test, prod DB topology, ack envelopes, cross-service raw-SQL pack read, TOCTOU sleep barriers, `LEGACY_USER_ID_GRACE` flip = ops decision gated on prod WARNING logs reading zero).

**New constraints for future work:** local pack-api boots (API, worker, and its integration tests) now require a reachable, migrated Postgres (boot head check; deploy discipline = migrate before deploy) · autogenerate never proposes `drop_table` — dropping an app's own table needs a hand-written migration.

## Top 5 recommended actions

1. **Set `STOREKIT_ENVIRONMENT=Production` on prod quiz-pack-api** (one `fly secrets set`; also make the code default fail-closed like `RC_ALLOWED_ENVIRONMENT`). Payoff: removes the one bug that would make every real pack purchase fail at launch.
2. **Add Postgres + `TEST_DATABASE_URL` to the quiz-agent CI job** (mirror the pack-api job's service block). Payoff: the repo's best tests — webhook ordering, entitlement, double-spend TOCTOU — actually gate merges instead of silently skipping.
3. **Wire Sentry + JSON logging into quiz-pack-api (main.py AND worker on_startup) and set `SENTRY_DSN` on both quiz-pack-api envs** (quiz-agent already has it on prod + staging, verified live 2026-07-18). Payoff: the billable pipeline stops being blind.
4. **Introduce `PublicQuestion` in quiz_shared and type the /question + InputResponse payloads.** Payoff: the busiest client contract enters OpenAPI and `/verify-api`, converting silent runtime drift into a CI diff.
5. **Add migration safety rails: `include_object` allowlist in both alembic envs + a boot-time head check (or `release_command`).** Payoff: closes both data-layer footguns — an unattended autogenerate proposing co-tenant DROPs, and code deploying ahead of schema — cheap insurance for an agent-driven repo.
