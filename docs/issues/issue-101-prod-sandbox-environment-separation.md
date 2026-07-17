# #101 — Prod vs sandbox environment separation (monetization trust)

**Triage:** infra · design-locked → agent (implementation in progress 2026-07-16, worktree `issue-101-env-separation`)
**Status:** Planned 2026-07-16 from the pre-MVP review (cross-stack seam finding, the single most severe item). **Founder decided 2026-07-16: Option A — separate environments** (2 now: prod + non-prod/staging; a 3rd likely later), with a **separate database** for the non-prod environment. **Design pass completed + adversarially verified 2026-07-16** (workflow `wf_e55b6f76`: RC docs research, Fly infra grounding via flyctl, codebase recon, adversarial fact-check of the RC routing claim).

## 1. Why

The backend RC ingest does **not** distinguish a sandbox purchase from a production one. During the imminent TestFlight, testers buy in the StoreKit **sandbox** (no real charge), RevenueCat forwards those events, and the backend writes **real production entitlement / credit rows** that the prod gate honors.

Consequences: (a) the €4.99 paywall is effectively **off** during TestFlight — every tester silently gets unlimited; (b) prod entitlement data is **polluted** with test rows; (c) you **cannot use TestFlight to validate the real money path** — which is exactly why the earlier on-device sandbox test (2026-07-12, `#93`/`#96 P1`) was ambiguous.

## 2. Findings (confirmed, file:line)

- **No environment gate in the RC ingest:** `apps/quiz-agent/app/usage/rc_service.py:352` `handle_webhook_event` dispatches on `event["type"]` only; `app/usage/rc_service.py:459` `_reconcile_subscription_state` (the REST sync path) folds `subscriptions` without reading `environment`/`is_sandbox`; `app/usage/entitlement.py:37-57` `account_is_entitled` reads only the `subscription` table. Nothing rejects a `SANDBOX` event.
- **Contrast — the pattern already exists on the pack side:** `apps/quiz-pack-api/app/api/deps.py:41` carries `storekit_environment`; the subscription path in quiz-agent never adopted it.
- **iOS uses one RC key for all environments:** `apps/ios-app/Hangs/Hangs/Services/PurchaseService.swift:98-102` `configure(withAPIKey: Config.revenueCatPublicSDKKey)` — no per-environment split, so the client itself can't be the gate.

## 3. Locked design (2026-07-16, grounded research + adversarial verification)

**Principle:** one deployment = one environment (the pattern quiz-pack-api already encodes via `storekit_environment`). Environment is decided by deploy-time config, enforced at every ingest boundary, and persisted on every money row.

### 3.1 RC webhook routing — one RC project, two env-filtered webhooks
- **Chosen:** keep the single RC project and single iOS public SDK key. Configure **two webhook integrations**: existing webhook → filter **Production purchases only** → prod URL; new webhook → filter **Sandbox purchases only** → staging URL, each with its **own Authorization header secret**. This exact pattern is named verbatim in RC docs and was adversarially confirmed; two RC projects are rejected (RC explicitly keeps sandbox+prod in one project; a split would force per-env iOS SDK keys for no gain).
- **Caveats (verified):** webhooks require the RC **Pro plan** (founder must confirm, §3.7); the `environment` field is **optional on TRANSFER events** → missing field is treated as reject, never assumed PRODUCTION.
- **Delivery filtering is not trusted:** both backends independently enforce §3.3 regardless of RC dashboard config.

### 3.2 Fly topology
- **Staging apps:** `quiz-agent-api-staging` (and `quiz-pack-api-staging`, needed because a TestFlight sandbox pack purchase would fail JWS verification against prod's `storekit_environment=Production`). One `fly.staging.toml` next to each existing `fly.toml` (`app = "<name>-staging"`, `[env] ENVIRONMENT = "staging"`, same build context); deploy via `fly deploy -c apps/<app>/fly.staging.toml`. This is Fly's documented multi-env pattern; no org split (overkill solo).
- **Staging DB:** **second logical DB on the existing `quiz-pack-db` cluster** — `fly postgres attach quiz-pack-db -a quiz-agent-api-staging --database-name quiz_pack_staging --superuser=false` (flags verified in local flyctl), attach/point both staging apps at the same `quiz_pack_staging`, mirroring prod's shared-DB + per-app alembic version tables. Satisfies "separate database" (fully separate data), costs **$0** (vs ~$2–3/mo for a second postgres app), stays unmanaged (never Fly Managed Postgres). Accepted caveat: shared machine/volume failure domain — fine while prod has no real users.
- **Volume:** staging quiz-agent needs its own `quiz_agent_data` volume in `cdg` (~$0.15/GB/mo). Total staging cost ≈ **$0.20/mo** (both apps auto-stop to zero).
- **Hetzner exit:** nothing here deepens Fly lock-in — plain containers, env vars, logical Postgres DBs, and RC webhook URLs that just get re-pointed.

### 3.3 Backend gating rule (quiz-agent)
- **New config:** `RC_ALLOWED_ENVIRONMENT` in `Settings` (`app/config.py`) — `PRODUCTION` on prod, `SANDBOX` on staging. **Unset → fail closed**: RC ingest refuses to process (mirrors the existing webhook-secret 503 behavior).
- **Normalization boundary (one helper in `rc_service.py`):** webhooks carry `environment: SANDBOX|PRODUCTION` (uppercase); REST v1 carries per-subscription boolean `is_sandbox`; normalize both to one value at ingest. **v1 is the sync API of record** — v2 has a verified open bug returning empty for sandbox subscriptions.
- **Webhook (`handle_webhook_event`):** event env ≠ allowed, **or env missing** → drop with HTTP 200 (no RC retry storm), log warning + Sentry event. No DB write of any kind.
- **REST sync (`_reconcile_subscription_state` / `apply_sync_snapshot`):** filter each `subscriptions` and `non_subscriptions` entry on `is_sandbox` vs allowed env before folding; mismatched entries never touch state.
- **Persist environment:** migration 0006 adds nullable `environment` column to `subscription` and `credit_ledger`; every new write stamps the normalized value. This is what made the current pollution un-auditable locally — cheap insurance, and lets a 3rd env be enforced by config alone.
- **Read gate (`account_is_entitled`):** honor only `subscription` rows whose `environment` matches allowed (NULL fails, post-quarantine there are none). Ledger stays write-gated + audited (ledger also holds non-RC kinds without environment semantics).

### 3.4 iOS targeting
- RC SDK key **unchanged** (one project ⇒ one key; verified there is no "staging RC key" to create).
- **New env config layer:** `Staging.xcconfig` (`ENVIRONMENT_NAME = Staging`, `API_BASE_URL = https://quiz-agent-api-staging.fly.dev`, `PACK_API_BASE_URL = https://quiz-pack-api-staging.fly.dev`) + composed `Release-Staging.xcconfig` / `Debug-Staging.xcconfig`, new shared scheme `Hangs-Staging` — exactly parallel to the existing Local/Prod mechanism consumed by `Config.swift` via Info.plist. New build configurations must be registered in the pbxproj.
- **TestFlight ships BOTH envs (founder request 2026-07-17):** fastlane `beta` lane pins `Hangs-Staging`/`Release-Staging`; new `release` lane pins `Hangs-Prod`/`Release-Prod` (shared `testflight_build` private lane; env-critical settings never ride Gymfile ambient defaults). `ios-release.yml` gained an `environment` choice input (staging default). Same bundle id + signing for both — one TF app, tester picks the build; staging installs as **"Trubbo Beta"** (display-name suffix = the on-device marker; deviation from the original "same display name" note, justified by the two-build requirement). Money path is testable **only** on the staging build — TF purchases are always StoreKit sandbox, prod gate drops them by design.

### 3.5 Secrets & migration parity (staging)
| Item | Value |
|---|---|
| `DATABASE_URL` | from `postgres attach` (quiz_pack_staging); set same URL on both staging apps |
| `RC_ALLOWED_ENVIRONMENT` | `SANDBOX` (prod app gets `PRODUCTION`) |
| `REVENUECAT_WEBHOOK_SECRET` | **new distinct value**, matches sandbox webhook's Authorization header |
| `REVENUECAT_API_KEY` | same secret key (one RC project) |
| `AUTH_JWT_SECRET` | **new value**, shared between the two staging apps only (staging must not accept prod JWTs) |
| `APP_ATTEST_*` | same app id; `APP_ATTEST_PRODUCTION=true` (TestFlight uses the production attest env), `_REQUIRED` mirrors prod |
| `LEGACY_USER_ID_GRACE` | mirror prod |
| `OPENAI/ELEVENLABS/TAVILY/OPENROUTER/LLM_GATEWAY/REDIS_URL` | reuse prod keys (voice loop must work on staging; cost-sensitive, no second vendor accounts) |
| `ADMIN_API_KEY`, `ADMIN_KEY`, `CORS_ORIGINS`, `LOG_LEVEL` | new admin keys; rest mirror prod |
| pack-api `storekit_environment` | `Sandbox` (fulfills the existing config comment) |
| Alembic | run both apps' migrations to head via `fly ssh console -a <staging-app>` (deploy ≠ migrate today; keep the manual pattern) |

### 3.6 Sandbox-row audit / quarantine (prod)
No local column exists, so classification is an out-of-band RC cross-reference: one-off script iterates prod `subscription` + RC-origin `credit_ledger` rows (`rc_event_id`/`store_txn_id` non-null), calls RC v1 `GET /subscribers/{app_user_id}` per `account_id`, matches on `rc_original_txn_id`/`original_transaction_id`, classifies via `is_sandbox`. Prod is founder-only, so the expected outcome is **all rows sandbox** → dry-run report → `pg_dump` backup → delete sandbox-origin subscription rows + their ledger grants/clawbacks → stamp any survivors `environment='PRODUCTION'`. Agent-autonomous per the auth/monetization delegation; dry-run output goes in the run report.

### 3.7 RC dashboard checklist — ✅ DONE 2026-07-17 (agent-driven via Playwright + founder login)
1. ✅ Webhooks accessible (plan OK).
2. ✅ Existing webhook "quiz-agent backend" → **Production only** (persisted, verified after reload).
3. ✅ New webhook "quiz-agent staging (sandbox)" → staging URL, **Sandbox only**, staging auth header.
4. ✅ Dashboard test event → staging responded **200**. (Gotcha found while verifying: a hand-crafted payload *without* `event_timestamp_ms` 500s in `_normalize_sub_event` — real RC events always carry it; cosmetic 500-vs-4xx hardening only.)
5. ✅ **v1 secret key** `backend-v1-sync` created (old "backend" key is v2 → v1 API 403 — root cause of the dead prod REST sync); deployed to both Fly apps + both local `.env`s; verified live with a v1 probe call (created + deleted a throwaway RC customer).

### 3.8 Third environment later
A 3rd env (dev) = one more `fly.<env>.toml` + `postgres attach --database-name quiz_pack_<env>` + secrets set + xcconfig/scheme. Constraint to know now: RC has only two purchase environments, and sandbox webhook delivery can't be split two ways — a dev env runs without RC webhooks (local StoreKit config testing), which is fine.

## 4. Implementation

Order matters: task 1 alone closes the prod bypass/pollution immediately (the §6 stopgap), before staging exists.

1. **Prod gate (backend):** add `RC_ALLOWED_ENVIRONMENT` to `Settings`; normalization helper in `rc_service.py`; enforce at `handle_webhook_event` (drop+200+Sentry on mismatch/missing), `_reconcile_subscription_state`/`apply_sync_snapshot` (per-entry `is_sandbox` filter), and `account_is_entitled` (env-matched rows only). Fail closed when unset.
2. **Migration 0006:** nullable `environment` on `subscription` + `credit_ledger`; stamp on every RC write path (`rc_service.py:280/314/563` + subscription upserts).
3. **Tests (`tests/test_webhooks.py`):** extend `_sub_event`/`_pack_event`/`_snapshot` builders with environment fields; add: SANDBOX webhook event → no write (grant, pack, refund paths); missing-environment event → dropped; sync snapshot with `is_sandbox: true` entry → not folded; allowed-env event still writes and stamps the column; unset `RC_ALLOWED_ENVIRONMENT` → fail closed. Acceptance test from §5 lives here.
4. **Deploy prod** with `RC_ALLOWED_ENVIRONMENT=PRODUCTION` + run migration 0006 (auth/monetization autonomy applies; migration heads-up per deploy rules).
5. **Audit/quarantine script** per §3.6: dry-run → backup → delete/stamp → report. Verify prod tables clean (§5 acceptance).
6. **Staging infra:** create `fly.staging.toml` for both apps; create staging volume; `postgres attach` → `quiz_pack_staging`; set §3.5 secrets; deploy both staging apps; run both alembic heads via ssh console; smoke: `/openapi.json` + a seeded quiz round.
7. **Founder gate:** §3.7 RC webhook clicks (surface interactively, not as a buried doc task).
8. **iOS staging target:** `Staging.xcconfig` + `Debug-Staging`/`Release-Staging` + pbxproj build configurations + `Hangs-Staging` scheme; fastlane `beta` lane gets explicit `scheme`/`configuration`.
9. **TestFlight validation:** trigger `/testflight`; founder makes a sandbox purchase on device → verify entitlement lands in `quiz_pack_staging` only, prod tables untouched, RC delivery log shows sandbox→staging routing (§5 acceptance).

### Decision log

| Decision | Choice | Why | Grounded in |
|---|---|---|---|
| RC routing | One project, two env-filtered webhooks + per-webhook auth secrets | Doc-sanctioned exact pattern; two projects would split the iOS SDK key for nothing | RC webhooks doc, adversarially confirmed verbatim |
| Missing `environment` on event | Reject (drop + Sentry) | Field is optional on TRANSFER; assuming PRODUCTION is the leak | Verified field tables |
| Sync API | RC REST **v1** `is_sandbox` | v2 has an open bug returning empty for sandbox subs | RC community threads (verified) |
| Fly topology | `-staging` app per backend + `fly.staging.toml` each | Fly's documented multi-env pattern; org split is overkill | Fly blueprints/monorepo docs |
| Staging DB | Logical DB `quiz_pack_staging` on existing `quiz-pack-db` | $0 vs $2–3/mo, supported `attach` flags, no managed-PG, Hetzner-portable | flyctl flag check + Fly docs; founder cost sensitivity |
| Env enforcement | Deploy-time `RC_ALLOWED_ENVIRONMENT`, fail-closed, checked at every ingest + read | Replicates quiz-pack-api's proven `storekit_environment` pattern; survives RC filter misconfig | Recon §2/§3 |
| Environment column | Add to `subscription` + `credit_ledger` | Current pollution was locally un-auditable; cheap; enables config-only 3rd env | Recon §6 |
| iOS | New `Hangs-Staging` scheme/xcconfigs; RC key unchanged; `beta` lane pins staging explicitly | Mirrors existing Local/Prod mechanism; RC has no per-env key; Gymfile ambient default was the prod-leak vector | Recon §4 |
| Quarantine | RC cross-reference script, dry-run → backup → delete | No local classifier exists; prod is founder-only | Recon §6 + prod-single-user memory |

## 5. Acceptance

- A `SANDBOX` RC event (webhook and REST-sync) does **not** grant entitlement or credits on the prod backend — covered by a test that feeds a sandbox-tagged event and asserts no prod write.
- The staging backend + DB accept sandbox purchases and gate correctly, so the founder can validate the real purchase→entitlement flow end-to-end from a TestFlight build without touching prod data.
- Prod `subscription`/`credit_ledger` audited clean of sandbox rows.

## 6. Notes

Interim mitigation if staging slips: prod backend simply drops non-`PRODUCTION` events (closes pollution + the free-unlimited bypass immediately) — but then purchases can't be tested until staging exists. Founder chose full separation, so treat the drop as a stopgap only. Ties to `project_93_subscription_backend_done`, `project_96_ios_mvp_completion`, `project_hosting_platform_decision`.
