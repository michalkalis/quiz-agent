# #93 — Subscription IAP + balíčky + free-tier: execution prompts

**Created:** 2026-07-08 · **Regenerated:** 2026-07-10 (re-prep — 2026-07-10 execution-model rails). **Why split:** large (backend + iOS + DB, 6 sessions) **and** sensitive (**class b — payments/monetization**). One human-prerequisite session + five code sessions.

**Execution model (founder decision 2026-07-10 — supersedes the v1 "class b → ready-for-human, Ralph never").** This issue is runnable **either**:
- **Mode (a) — autonomous loop:** repeated fresh-context sessions. Each picks the next unblocked, unticked session (deps merged), pastes its fenced block, implements, runs its `Done =` gate. On red → retry within the prompt's budget then **stop and surface** (never tick on red, never skip).
- **Mode (b) — Fable-orchestrated:** one **Claude Fable 5** coordinator holds the plan + Status table and **spawns one subagent per session** (passing that session's fenced block + the routed model), sequencing by the dependency column, staying out of raw file contents. Never run parallel agents in one checkout (use worktrees).

Both modes obey the same rails: **maker≠checker on payment code**, `[HUMAN]` gates preserved, **no autonomous deploy**.

**Maker≠checker (payment/entitlement sessions A-helper, B, C, D).** `Done =` green is **not** sufficient to tick these. After the maker's `Done =` passes, set `Done ✅` on the Status table but leave the box unticked and **spawn a separate fresh-context adversarial reviewer (opus, a different context than the maker)** to disprove the diff against Design §1–4. Reviewer green → set `Reviewed = ✅`, **then** commit+push+tick. Reviewer finds a defect → it returns a **fix task**; feed it to a fresh maker session (keep `Reviewed = ⬜`), which fixes + re-runs `Done =`, then re-review. **Tick/push only after both `Done = ✅` and `Reviewed = ✅`.** Non-payment sessions (A-schema, E, the trivial 30-cap edit) carry `Reviewed = n/a`. **Class-b note:** the split-issue skill's blanket "payments → never autonomous" default is **superseded for this issue** by the recorded founder decision 2026-07-10 in the issue header — honor these rails, not the blanket ban.

**How to use:** open a fresh session (or spawn a subagent), paste one fenced ` ``` ` block below, and go. Each block is self-contained — it names its routed model, the files to read first, the build steps, an objective `Done =` check, and (for payment sessions) its review leg — so a session needs neither this conversation nor the others' context. The dependency markers below say what must be **merged** before a session starts. Every session lands committed on `main`, **no deploy** (deploy + migration `0005` + secrets stay founder-gated).

**Parent plan:** [`issue-93-subscription-iap-packs.md`](./issue-93-subscription-iap-packs.md) (gates: re-prep P3 ready-check READY · design-soundness SOUND 0.68 · P5 READY · SOUND 0.82).
**Cost model:** [`../research/issue-93-cost-model-2026-07-08.md`](../research/issue-93-cost-model-2026-07-08.md).

---

## Recon snapshot

Shared context every session reads instead of re-mapping. Paths/symbols confirmed 2026-07-08.

### Backend (`apps/quiz-agent`)
- **Quota:** `FREE_MONTHLY_LIMIT = int(os.getenv("FREE_MONTHLY_LIMIT","100"))` — `app/usage/tracker.py:29`. Month window `_month_start()` :36-37, `_next_reset()` :40-45, `_read_month()` :59-84 (sums `DailyUsage.questions_count` since 1st of UTC month).
- **`check_limit(self, subject_id: str) -> tuple[bool,int,datetime]`** — `tracker.py:86-95` (returns `(allowed, remaining, resets_at)`; **non-mutating**). **`record_question(self, subject_id: str) -> int`** — `tracker.py:97-141` (the single mutating consume point; upserts a visible row, no-ops increment for premium today).
- **`is_premium` is NOT a subscription column** — read as latest `DailyUsage.is_premium` (`_read_month()` :76-84, `ORDER BY usage_date DESC LIMIT 1`); set via `set_premium()` :166-184; `is_premium()` accessor :186-189. The new gate **stops reading this**; leave the column in place (drop in later cleanup).
- **Gate call sites:** start-gate 429 at `app/api/routes/quiz.py:60-75` (`error:"quota_limit_reached"`), `record_question` at `quiz.py:148` (after retrieval, before session transition). Per-answer: `app/quiz/flow.py:244-263` sets `result.usage_limit_error` (re-raised as 429 at `quiz.py:218`), retrieval at `flow.py:267`, `record_question` at `flow.py:286`. ⚠️ **Pre-record 500:** retrieval can raise **before** `record_question` — the reason consume must stay in `record_question`, never `check_limit`.
- **Alembic head = `0004_refresh_token_subject`** (chain `0001_auth_phase1`→`0002_app_attest`→`0003_users`→`0004_refresh_token_subject`). `0005` down_revision = `0004_refresh_token_subject`.
- ⚠️ **DB gotcha (load-bearing):** this app's migrations MUST target the **`alembic_version_quiz_agent`** version table, not the default `alembic_version` — `DATABASE_URL` is a Postgres shared with `quiz-pack-api`'s own Alembic history (see `tests/test_alembic_version_table_isolation.py`). Follow how `0004` configures this; `0005` must do the same or it corrupts the other app's migration state.
- **`DailyUsage`** model `app/db/models.py:142-155` (composite PK `subject_id,usage_date`). **`User`** model :158-190 — its docstring (:159-168) *describes* the anon→user fold ("folds anon's `daily_usage` into this user, stamps `AnonymousIdentity.upgraded_to_user_id`") but ⚠️ **the fold logic is NOT here** — it lives in an auth/migration route. Session D must `grep -rn "upgraded_to_user_id" apps/quiz-agent` to find the real fold function (start at `tests/test_refresh_subject_migration.py`).
- **`/usage/{user_id}` GET** `app/api/routes/misc.py:65-73` — returns a **raw dict** from `usage_tracker.get_usage(...)`, **no `response_model`**; admin `/usage/{id}/premium` POST :76-93 (`X-Admin-Key` gated). ⚠️ **There is NO `packages/shared` Pydantic model for `/usage`** (`packages/shared/quiz_shared/models/` has only phase/rating/session/question/participant). For `/verify-api` to have anything to check, Session B must introduce a typed `UsageResponse` `response_model` (add fields there), not "extend an existing model".
- **Tests** (`apps/quiz-agent/tests/`): DB fixture `conftest.py:36-52` `db_sessionmaker` (⚠️ **skips** if `TEST_DATABASE_URL` unset — a run that skips is NOT a pass; assert tests actually execute). Seed pattern: `test_usage_tracker.py` (`_seed_row()` inserts `DailyUsage` directly). HTTP pattern: `test_admin_premium.py:28-39` (bare `FastAPI()` + only the router under test + `httpx.AsyncClient(ASGITransport(app))`). External-call mock: `test_mcq_evaluator.py` (`AsyncMock` patched onto the method, not global client). Gate: `cd apps/quiz-agent && pytest tests/ -v`.

### iOS (`apps/ios-app/Hangs`)
- Project `apps/ios-app/Hangs/Hangs.xcodeproj` (no workspace). Scheme **`Hangs-Local`** (API → `http://localhost:8002`). Build/test via shell `xcodebuild -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (pipe to `tail`) or the **`ios-tester`** agent; drive UI only via the **`ios-ui-driver`** agent (never from the main session).
- Files: `Hangs/Services/StoreManager.swift`, `Hangs/Services/PurchaseService.swift`, `Hangs/Views/PaywallView.swift`, `Hangs/Services/NetworkService.swift`, `Hangs/ViewModels/QuizViewModel.swift`, `Hangs/Models/UsageInfo.swift`.
- **`UsageInfo`** (`Models/UsageInfo.swift:11-26`) `struct UsageInfo: Codable, Sendable, Equatable` — fields `userId, isPremium, questionsUsed, questionsLimit: Int?, remaining: Int?, resetsAt: String` (+ computed `resetDate`, `isLimitReached`); same file has `QuotaLimitError`. Session E adds `subscriptionStatus` + `creditBalance` (+ `CodingKeys`).
- ⚠️ **RevenueCat SDK is ABSENT** (`Package.resolved` pins sentry/snapshot-testing/etc., no `Purchases`) — Session E adds the SPM package from scratch.
- **Current IAP = pure StoreKit 2** (no RC): `LivePurchaseService` in `PurchaseService.swift` (behind a `PurchaseService` protocol, so `StoreManager` stays testable) uses `Product.products(for:)`, `product.purchase()`, `Transaction.updates/currentEntitlements`, `AppStore.sync()`. Single **non-consumable** id `StoreProduct.unlimited = "com.carquiz.unlimited"` (`enum StoreProduct`, `StoreManager.swift`) — retired by this issue.
- **Backend-signal today:** `QuizViewModel.notifyPremiumPurchased()` (`QuizViewModel.swift:635`, called from `ContentView.swift:143`) just `refreshUsage()` → `GET /api/v1/usage/{user_id}`; no direct purchase-notify POST exists. Session E adds the `POST /entitlements/sync` call here.
- **Auth POST pattern** (`NetworkService.swift`): actor `NetworkService`, private `sendAuthorized(_ request:) async throws -> (Data,URLResponse)` (:65-87) attaches `Authorization: Bearer <token>`, retries once on 401. 429 branch (:228-234, repeated ~398, ~461) decodes `QuotaLimitErrorWrapper` → `NetworkError.quotaLimitReached`. Endpoint build: `baseURL.appendingPathComponent("/api/v1/usage/\(userId)")`. New `POST /entitlements/sync` follows this exact shape.

---

## Locked decisions

Lifted verbatim by intent from the parent plan's `## Resolved design decisions` + founder decisions. **Do not re-litigate — these are settled.**

| # | Decision |
|---|---|
| Founder-1 | Free tier **100 → 30** questions / calendar month. |
| Founder-2 | Subscription = **UNLIMITED** questions (not metered credits). Price **€4.99/mo**, annual **€29.99/yr**. |
| Founder-3 | Packs buyable by **free users without a sub** (+100 for ~€1.99), **never expire**. |
| Founder-4 | **ONE paid tier in v1**; data model forward-compatible for more tiers later (no `is_premium` boolean). |
| Founder-5 | **Execution = autonomous-loop OR Fable-orchestrated** under maker≠checker rails (2026-07-10; supersedes "class b → Ralph never"). Adversarial opus review on every payment path; migration/secret deploys founder-gated; console-provisioning + live-sandbox legs `[HUMAN]`. |
| D-RC | **Adopt RevenueCat** (SDK on iOS + REST/webhooks on backend); backend owns credit ledger + quota gate, RC owns receipt validation + sub lifecycle. |
| D-tables | Entitlement = **tables** (`product` + `subscription` + `credit_ledger`), not a boolean. |
| D-ledger | Server-side **append-only credit ledger**, balance = `SUM(delta)`; no consumable restore. |
| D-idem | **GRANT dedupe `UNIQUE(store_txn_id) WHERE kind='grant'`** (global), **CLAWBACK dedupe `UNIQUE(rc_event_id) WHERE kind='clawback'`** (disjoint partial indexes). |
| D-bridge | **`POST /entitlements/sync`** = one-shot RC REST pull post-purchase; hot path never calls RC. |
| D-ids | Pinned strings: entitlement **`unlimited`**; subs **`com.carquiz.unlimited.monthly`** / **`.annual`**; pack **`com.carquiz.pack.questions100`** (+100). |
| D-order | Webhook events split **extend** (max-wins on `expires_at`) vs **revoke** (writes shorter `expires_at`/`expired`); ordered by **`last_event_ts_ms`** watermark (apply iff strictly newer); sync = full-state snapshot reconcile setting `last_event_ts_ms=request_date_ms` (only if `request_date_ms ≥ stored` — monotonic, never regresses). |
| D-pk | **`subscription.account_id` PK/UNIQUE** (webhook `ON CONFLICT` target). |
| D-merge | Anon→sign-in **subscription fold = MERGE** (row-wise winner = greater-`expires_at` row wholesale, `last_event_ts_ms`=field-max, delete anon row); **ledger fold = bare re-key** (collision-free, global indexes). |
| D-grace | **`status ∈ {active, grace}`** counts as entitled (Apple billing-retry window). |
| D-gate | One shared gate in the usage/entitlement layer, order **sub → free-30 → credits → deny**; **consume in `record_question`** only; **default-deny** on null account (preserves #89/#90). |
| D-helper | **All sub-state math lives in one pure helper** (`app/usage/subscription_state.py`, Session A) — webhook (C), sync (C), and fold (D) import it, never re-embed max-wins/revoke/watermark/merge. Its `tests/test_subscription_state.py` is the producer of Session A's mode-(a) hard gate. |

---

## Session breakdown

Dependency + parallel + model-routing markers. `Reviewed` column = the durable maker≠checker state the loop resumes from (`✅`/`⬜`/`n/a`).

| Session | Tasks | Model (mode b) | Risk | Depends on (merged) | Reviewed |
|---|---|---|---|---|---|
| **0 · [HUMAN] provisioning** | Console + secrets | — (founder) | — (manual) | — | n/a |
| **A-schema** | ORM models, migration `0005`, seed | **sonnet** | med (schema) | 0 | n/a |
| **A-helper** | pure `subscription_state` helper + `test_subscription_state.py` | **opus** | high (concurrency core) | 0 | ⬜ |
| **B · Entitlement gate** | EntitlementService, `FREE_MONTHLY_LIMIT` 30 (**haiku** one-liner), `check_limit`/`record_question` wiring, typed `/usage` `UsageResponse`, `test_entitlement.py` | **opus** | high (hot path) | A-schema, A-helper | ⬜ |
| **C · Webhook + sync** | `/webhooks/revenuecat`, pack handling, `/entitlements/sync`, `test_webhooks.py` | **opus** | high (payments) | A-schema, A-helper (+ 0 secret) | ⬜ |
| **D · Account keying** | Extend #61 fold: subscription MERGE + ledger re-key + 2 fold tests | **opus** | high (payments) | A-schema, A-helper | ⬜ |
| **E · iOS** | RC SPM + SDK swap, PaywallView, `UsageInfo` Codable, post-purchase sync, `/verify-api`, live sandbox check | **sonnet** (exempt) | high | B, C (+ 0 offerings) | n/a |

**A-schema and A-helper** are one merged commit in mode (a) (run as Session A below, in order); in mode (b) the coordinator spawns a **sonnet** subagent for the schema and an **opus** subagent for the helper. **A-helper is the payment-critical part → it gets the opus adversarial review; A-schema does not.** B, C, D each block on both A parts merged. B and C and D may run in parallel **only in separate worktrees** (all three depend solely on A). **E** blocks on B + C. **Session E is exempt from maker≠checker** (sonnet, no reviewer): entitlement derivation is **server-side default-deny** — an iOS bug can only *under-serve* (fail to unlock a paid user, who retries), never *over-grant*, since the server decides entitlement. That asymmetry is why E needs neither opus nor a reviewer.

---

## Human prerequisites (Session 0 — founder, class b, `[HUMAN]`)

Do these **before** A-schema's seed, Session C's webhook, and Session E's offerings. Assume zero prior knowledge; exact steps:

1. **App Store Connect → create IAP products** (My Apps → the Trubbo/Hangs app → Monetization → In-App Purchases / Subscriptions):
   a. A **Subscription Group** (e.g. "Trubbo Unlimited"), with two auto-renewable subscriptions: product id **`com.carquiz.unlimited.monthly`** price **€4.99**, and **`com.carquiz.unlimited.annual`** price **€29.99**.
   b. One **Consumable** in-app purchase: product id **`com.carquiz.pack.questions100`**, price **~€1.99**.
   Fill the required localizations + review screenshot so they reach "Ready to Submit".
2. **RevenueCat dashboard** (app.revenuecat.com):
   a. Create/open the project, add the **App Store** app (bundle id `com.carquiz.*`), paste the **App Store Connect shared secret / in-app-purchase key**.
   b. Create **Entitlement** identifier **`unlimited`**. Attach the two subscription products to it. Add the pack product as a **product** (not attached to the entitlement — packs are consumable credits, tracked by our backend, not RC entitlements).
   c. Create an **Offering** (e.g. "default") with packages for monthly, annual, and the pack.
   d. **API keys:** copy the **public SDK key** (for iOS, Session E) and a **secret REST API key** (for backend `/entitlements/sync`, Session C).
   e. **Webhook:** Integrations → Webhooks → add URL `https://<backend-host>/webhooks/revenuecat`, set an **Authorization header value** (a long random secret) — this is the shared secret Session C verifies.
3. **Backend secrets (Fly, founder-gated):** `fly secrets set -a <quiz-agent-app> REVENUECAT_API_KEY=<secret REST key> REVENUECAT_WEBHOOK_SECRET=<the Authorization value from 2e>`. For local dev add both to `apps/quiz-agent/.env`.
4. Tell the executing sessions these exist. **Reply in-session with the RevenueCat public SDK key** when Session E asks (it goes in the iOS app config, not a backend secret).

---

## Ready prompt — Session A (DB layer: schema + helper)

> **Model routing:** mode (a) run as one fresh session (schema then helper, one commit). Mode (b): spawn a **sonnet** subagent for steps 1–2 (schema/migration) and an **opus** subagent for steps 3–4 (`subscription_state` helper). **A-helper (steps 3–4) is payment-critical → its output takes the opus adversarial review leg below; A-schema (steps 1–2) does not (`Reviewed = n/a`).**

```
Issue #93 (subscription IAP), Session A — DB layer (schema + subscription-state helper). Class b (payments): land committed on main, do NOT deploy, migration/secrets are founder-gated. Work in apps/quiz-agent.

Scope: create the entitlement schema + a shared subscription-state helper. Do NOT touch the quota gate, webhook, iOS, or the anon fold — those are Sessions B/C/D/E. Do NOT backfill or drop `is_premium`.

Read first:
- docs/issues/issue-93-subscription-iap-packs.md → Design §1, §4, and Resolved design decisions (D-tables, D-idem, D-pk, D-order, D-merge, D-ids, D-helper).
- app/db/models.py:142-190 (DailyUsage + User); alembic/versions/0004_refresh_token_subject.py (head + how it targets the alembic_version_quiz_agent table — the SHARED-Postgres gotcha).
- tests/conftest.py:36-52 (db_sessionmaker) and tests/test_usage_tracker.py (seed pattern).

Build:
1. [A-schema] ORM models in app/db/models.py — `Product{product_id PK, kind, tier, credit_amount}`, `Subscription{account_id PK/UNIQUE, product_id, status, expires_at, rc_original_txn_id, last_event_ts_ms BIGINT NULL, updated_at}`, `CreditLedger{id, account_id, delta, kind, reason, store_txn_id NULL, rc_event_id NULL, created_at}`.
2. [A-schema] Migration alembic/versions/0005_*.py (down_revision=0004_refresh_token_subject): create the 3 tables; `subscription.account_id` PK/UNIQUE; two PARTIAL unique indexes — `UNIQUE(store_txn_id) WHERE kind='grant'` (global) and `UNIQUE(rc_event_id) WHERE kind='clawback'`; seed `product` rows for the 3 pinned ids (credit_amount=100 on the pack). Tables-only, no is_premium backfill. MUST target the alembic_version_quiz_agent table exactly like 0004.
3. [A-helper] A pure helper app/usage/subscription_state.py: `apply_subscription_event(current, event) -> new_state` and `merge_subscription_rows(a, b) -> winner` implementing D-order + D-merge: extend events (INITIAL_PURCHASE/RENEWAL/upgrade PRODUCT_CHANGE/UNCANCELLATION) max-wins on expires_at (tie → status precedence active>grace>expired), revoke events (REFUND/CHARGEBACK/immediate CANCELLATION/downgrade PRODUCT_CHANGE/EXPIRATION) write shorter expires_at/expired, watermark `last_event_ts_ms` (apply iff strictly newer; NULL watermark → first event applies), grace status; merge = ROW-WISE winner by max expires_at (whole row taken as one unit, keeping its status), last_event_ts_ms = field-max (never synthesizes a {status, expires_at} combo neither source held). NO DB or network in this helper — pure functions over dataclasses/dicts, so C and D both import it.
4. [A-helper] Unit tests tests/test_subscription_state.py for the helper: extend max-wins, revoke moves expiry backward / flips expired, status precedence on ties, stale-event dropped, NULL-watermark-first-applies, merge row-wise (no synthesized state).

Done =
- `cd apps/quiz-agent && TEST_DATABASE_URL=<local test pg> alembic upgrade head && alembic downgrade -1` both clean; after upgrade `SELECT count(*) FROM product` = 3 and both partial indexes exist (`\d+ credit_ledger`).
- `cd apps/quiz-agent && pytest tests/test_subscription_state.py -v` green (tests RUN, not skipped).
- `ruff` clean on touched files.

Then (A-helper only — payment path, maker≠checker):
- On Done green, set A-helper `Done ✅` in ## Status but leave the box unticked. Spawn a SEPARATE fresh-context adversarial reviewer (opus, a different context than the maker) tasked ONLY to disprove app/usage/subscription_state.py + its tests against Design §1 (D-order/D-merge): can a revoke fail to move expiry backward? can max-wins swallow a real revoke? does the NULL-first watermark apply? can the merge synthesize a {status, expires_at} combo neither row held? If the reviewer finds a defect it returns a fix task → a fresh maker session fixes + re-runs Done, then re-review. Only when the reviewer is green set A-helper `Reviewed = ✅`.
- A-schema is `Reviewed = n/a` (no reviewer).

Commit + push (main, no deploy) once A-schema is green AND A-helper is Reviewed ✅. Tick Session A rows in docs/issues/issue-93-execution-prompts.md ## Status and the DB/helper task lines in the parent issue.
```

## Ready prompt — Session B (Entitlement gate)

> **Model routing:** **opus** (hot-path quota concurrency; must preserve #89/#90). The `FREE_MONTHLY_LIMIT` 100→30 one-liner is trivial (**haiku**-class) — do it inline. **Payment-critical → takes the opus adversarial review leg.**

```
Issue #93, Session B — entitlement gate + free-tier 30. Class b (payments): land committed on main, no deploy. Requires Session A merged (schema + subscription_state helper). Work in apps/quiz-agent.

Scope: make the quota gate read the new tables and enforce sub→free-30→credits→deny, and type the /usage response. Do NOT write the webhook or sync endpoint (Session C), the anon fold (Session D), or iOS (Session E). Keep the check(non-mutating)→record(mutating) split intact.

Read first:
- docs/issues/issue-93-subscription-iap-packs.md → Design §3 + decisions D-gate, D-grace.
- app/usage/tracker.py:29,36-45,59-95,97-141,166-189 (limits, window, check_limit, record_question, is_premium).
- app/api/routes/quiz.py:60-75,148,218 and app/quiz/flow.py:244-263,267,286 (gate + record call sites; note retrieval can 500 BEFORE record).
- app/api/routes/misc.py:65-93 (/usage returns a raw dict — there is NO shared Pydantic model yet).
- app/db/models.py (Subscription/CreditLedger from Session A); tests/test_usage_tracker.py + test_admin_premium.py (test patterns).

Build:
1. EntitlementService (app/usage/entitlement.py, or fold into UsageTracker): `is_entitled(account_id)` = subscription.status ∈ {active,grace} AND expires_at>now(); `credit_balance(account_id)` = SUM(credit_ledger.delta). Both NON-MUTATING, DEFAULT-DENY on null/absent account_id.
2. FREE_MONTHLY_LIMIT default 100 → 30 (tracker.py:29). Window/reset untouched.
3. Wire check_limit (non-mutating) to resolve sub → free<30 → credits>0 → deny (Design §3 steps 1-4); stop reading daily_usage.is_premium; keep the (allowed,remaining,resets_at) return.
4. Wire record_question (single consume point) to re-derive the path and apply EXACTLY ONE effect: entitled→row only; free→counter upsert (unchanged); else→one guarded credit debit (`INSERT … WHERE (SELECT SUM(delta)…)>0`). Symmetric; a pre-record 500 debits nothing.
5. Introduce a typed `UsageResponse` response_model (in packages/shared or app/api) for GET /usage that ADDS `subscription_status` + `credit_balance` (additive only; keep is_premium etc.), and set it as the endpoint's response_model so OpenAPI types it.
6. tests/test_entitlement.py: test_free_cap_is_30 (429 at 30, ok at 29); test_active_sub_unlimited; test_grace_sub_unlimited; test_credit_debit_once_per_served; test_pre_record_retrieval_500_no_debit (INTEGRATION-level — drive flow.process_answer/`/start` with the retriever mocked to raise AFTER check_limit, BEFORE record_question; assert credit_ledger SUM(delta) unchanged — NOT a tracker unit test); test_null_account_denied; test_no_double_spend.

Done = `cd apps/quiz-agent && pytest tests/test_entitlement.py -v` green (RUN, not skipped); `ruff` clean on touched files.

Then (payment path, maker≠checker): on Done green, set B `Done ✅` in ## Status, leave box unticked, spawn a SEPARATE fresh-context adversarial reviewer (opus) to disprove the diff against Design §3: does the entitlement read default-deny on a null account (no #89 bypass)? is consume a single atomic guarded write, and does record_question re-derive the path independently so a check→record race can't double-spend (#90 TOCTOU)? is exactly one effect applied per served question, symmetric across sub/free/credit? Defect → fix task → fresh maker fixes + re-runs Done → re-review. Reviewer green → set B `Reviewed = ✅`.

Commit + push (main, no deploy) only after Done ✅ AND Reviewed ✅. Tick Session B in ## Status + the parent Entitlement/quota + /usage task lines.
```

## Ready prompt — Session C (Webhook + sync bridge)

> **Model routing:** **opus** (payment-critical; out-of-order/replay/revoke reasoning). **Takes the opus adversarial review leg.**

```
Issue #93, Session C — RevenueCat webhook + /entitlements/sync. Class b (payments): land committed on main, no deploy. Requires Session A merged; needs Session 0's REVENUECAT_WEBHOOK_SECRET + REVENUECAT_API_KEY (fall back to reading them from env/.env). Work in apps/quiz-agent.

Scope: build the two RC-facing endpoints and their ledger/subscription writes. Do NOT change the gate (Session B) or the anon fold (Session D) or iOS (Session E). Reuse Session A's app/usage/subscription_state.py helper for ALL subscription-state math — don't re-implement max-wins/revoke/watermark.

Read first:
- docs/issues/issue-93-subscription-iap-packs.md → Design §2, §4 + decisions D-idem, D-bridge, D-order, D-pk, D-grace, D-helper.
- app/usage/subscription_state.py (Session A helper) and app/db/models.py (Subscription/CreditLedger).
- app/api/routes/misc.py (router mounting pattern) + tests/test_admin_premium.py (ASGITransport HTTP-test pattern) + tests/test_mcq_evaluator.py (AsyncMock external-call pattern).

Build:
1. POST /webhooks/revenuecat (new app/api/routes/webhooks.py): verify the shared-secret `Authorization` header (constant-time compare) BEFORE parsing the body → 401 else. Upsert subscription with ON CONFLICT(account_id). Gate SUBSCRIPTION events on event_timestamp_ms > last_event_ts_ms (NULL watermark → apply); extend (INITIAL_PURCHASE/RENEWAL/upgrade PRODUCT_CHANGE/UNCANCELLATION) via the helper's max-wins; revoke (REFUND/CHARGEBACK/immediate CANCELLATION/downgrade PRODUCT_CHANGE) writes shorter expires_at/expired; EXPIRATION→expired; BILLING_ISSUE→grace (grace_period_expiration_at_ms). Watermark scoped to SUBSCRIPTION state only.
2. Pack events in the same endpoint: NON_RENEWING_PURCHASE → +credit_amount grant (store_txn_id=transaction_id, rc_event_id=event id), deduped by the GRANT partial index — NOT gated by the subscription watermark (impl note ii). REFUND/CANCELLATION of a pack → clawback (−credit_amount, rc_event_id=refund event id, store_txn_id=original). CONSUMPTION_REQUEST → report balance to RC.
3. POST /entitlements/sync (authenticated; webhooks.py or new entitlements.py): one-shot RC REST GET /subscribers/{app_user_id}. Subscription = FULL-STATE overwrite of status/expires_at from subscriptions[pid], set last_event_ts_ms=request_date_ms — but ONLY if request_date_ms ≥ stored last_event_ts_ms (monotonic; a stale older snapshot no-ops, never regresses status/expiry/watermark). Packs from non_subscriptions[pid][] → grants keyed on store_transaction_id, deduped on store_txn_id.
4. tests/test_webhooks.py (mock the RC REST call with AsyncMock): test_grant_idempotent_sync_then_webhook; test_refund_revokes_active_sub; test_stale_renewal_after_refund_noop; test_newer_webhook_after_sync_applies (sync sets watermark=request_date_ms, then RENEWAL with ts>request_date_ms MUST apply); test_first_event_null_watermark_applies; test_pack_grant_not_gated_by_sub_watermark; test_clawback_once; test_webhook_auth_rejects_bad_secret (401 before body parse).

Done = `cd apps/quiz-agent && pytest tests/test_webhooks.py -v` green (RUN, not skipped); `ruff` clean on touched files.

Then (payment path, maker≠checker): on Done green, set C `Done ✅` in ## Status, leave box unticked, spawn a SEPARATE fresh-context adversarial reviewer (opus) to disprove the diff against Design §2: is the auth check constant-time and BEFORE body parse? does the ordering guard defeat stale replay in BOTH directions (an old RENEWAL after a refund no-ops; a genuine newer REFUND revokes)? does sync converge with webhooks (never resurrect a refunded sub) yet a strictly-newer webhook still apply? are grant/clawback exactly-once across sync+webhook (split idempotency, disjoint by kind)? is the pack grant NOT gated by the sub watermark? Defect → fix task → fresh maker fixes + re-runs Done → re-review. Reviewer green → set C `Reviewed = ✅`.

Commit + push (main, no deploy) only after Done ✅ AND Reviewed ✅. Tick Session C in ## Status + the parent webhook/sync task lines.
```

## Ready prompt — Session D (Account keying / anon→sign-in fold)

> **Model routing:** **opus** (payment-critical merge under a UNIQUE constraint). **Takes the opus adversarial review leg.**

```
Issue #93, Session D — extend the anon→sign-in fold for subscription + credits. Class b (payments): land committed on main, no deploy. Requires Session A merged (uses its merge helper). Work in apps/quiz-agent.

Scope: ONLY the account-keying fold. Do NOT touch the gate, webhook, or iOS. Reuse app/usage/subscription_state.py merge_subscription_rows — don't re-implement the merge rule.

Read first:
- docs/issues/issue-93-subscription-iap-packs.md → Design §1 "Account keying" + "Subscription fold = MERGE" + decisions D-merge, D-pk, D-helper.
- app/db/models.py:158-190 (User docstring describes the fold) — ⚠️ the fold LOGIC is NOT here. FIRST run `grep -rn "upgraded_to_user_id" apps/quiz-agent` and read tests/test_refresh_subject_migration.py to locate the actual fold function (an auth/migration route). Extend THAT function, inside its existing transaction.

Build:
1. In the located fold: after the existing daily_usage fold, add —
   - subscription: if BOTH an anon-keyed and a user-keyed subscription row exist for the account → merge_subscription_rows(anon,user) into the user-keyed row, DELETE the anon row; if only the anon row exists → plain re-key UPDATE account_id→user_id. All inside the same fold transaction (so a UNIQUE(account_id) collision can never abort sign-in).
   - credit_ledger: bare re-key UPDATE account_id (anon→user) — collision-free (global grant/clawback indexes, append-only).
   - Call RC logIn/alias so RC history merges (if the RC client wrapper exists; else leave a TODO — do not block the fold on it).
2. tests (in tests/test_entitlement.py, matching Session B's file):
   - test_anon_to_signin_preserves_credits — ledger + subscription re-keyed, no double-grant on a replayed webhook.
   - test_anon_to_signin_merges_two_sub_rows — seed BOTH an anon- and user-keyed subscription row with DIFFERENT expires_at → run fold → assert exactly ONE surviving user-keyed row with max-wins expires_at + winning status + larger last_event_ts_ms, and NO UNIQUE-violation/abort.

Done = `cd apps/quiz-agent && pytest tests/test_entitlement.py -k "anon_to_signin" -v` green (RUN, not skipped); full `cd apps/quiz-agent && pytest tests/ -v` still green; `ruff` clean on touched files.

Then (payment path, maker≠checker): on Done green, set D `Done ✅` in ## Status, leave box unticked, spawn a SEPARATE fresh-context adversarial reviewer (opus) to disprove the diff against Design §1 (fold): can a plain re-key abort on the UNIQUE(account_id) when a user-keyed row exists (i.e. is the MERGE path actually taken)? does the merge use the helper's row-wise rule (no synthesized {status,expires_at})? is the whole fold atomic (one transaction, can't leave two rows)? is the ledger re-key genuinely collision-free? Defect → fix task → fresh maker fixes + re-runs Done → re-review. Reviewer green → set D `Reviewed = ✅`.

Commit + push (main, no deploy) only after Done ✅ AND Reviewed ✅. Tick Session D in ## Status + the parent Account-keying task line.
```

## Ready prompt — Session E (iOS RevenueCat + paywall)

> **Model routing:** **sonnet, EXEMPT from maker≠checker** (no adversarial reviewer, `Reviewed = n/a`). Rationale: entitlement derivation is **server-side default-deny** — an iOS-side bug can only *under-serve* (fail to unlock a paid user, who retries), never *over-grant*, since the server (not the client) decides entitlement. That asymmetry is why E needs neither opus nor a reviewer. The **live-sandbox purchase leg is `[HUMAN]`** (StoreKit sandbox can't be driven headless).

```
Issue #93, Session E — iOS RevenueCat SDK + paywall + entitlement sync. Class b: land committed on main, no deploy. Requires Sessions B + C merged (needs the extended /usage fields + the /entitlements/sync endpoint), and Session 0's RevenueCat public SDK key + configured Offering. ASK the founder in-session for the RC public SDK key. Work in apps/ios-app/Hangs.

Scope: swap the iOS purchase stack to RevenueCat, render offerings, sync entitlement post-purchase, keep the Codable in sync. Do NOT change backend.

Read first:
- docs/issues/issue-93-subscription-iap-packs.md → Design §2 (iOS) + decisions D-RC, D-ids, D-bridge.
- Hangs/Services/StoreManager.swift + PurchaseService.swift (current StoreKit2 stack, enum StoreProduct, PurchaseService protocol), Views/PaywallView.swift, ViewModels/QuizViewModel.swift:635 (notifyPremiumPurchased) + ContentView.swift:143, Services/NetworkService.swift:65-87,228-234 (sendAuthorized + 429), Models/UsageInfo.swift:11-26.
- .claude/rules/ios.md (scheme Hangs-Local; build/test via xcodebuild or ios-tester agent; UI only via ios-ui-driver agent).

Build:
1. Add the RevenueCat "Purchases" Swift Package (SPM) to Hangs.xcodeproj. Configure Purchases with the public SDK key + app_user_id = the durable account id, on app launch.
2. Replace the StoreKit2 internals of LivePurchaseService with RevenueCat (keep the PurchaseService protocol so StoreManager stays testable). Retire com.carquiz.unlimited non-consumable. Offerings = sub monthly+annual + consumable pack (com.carquiz.pack.questions100).
3. PaywallView renders RC Offerings (subscribe + "buy pack" path for free users); "restore purchases" = subscription only.
4. Add subscriptionStatus + creditBalance (+ CodingKeys) to UsageInfo to match the extended backend UsageResponse.
5. After any successful SDK purchase, call POST /api/v1/entitlements/sync via NetworkService (same sendAuthorized shape) BEFORE re-fetching /usage (wire into QuizViewModel.notifyPremiumPurchased). 429→paywall path unchanged.

Done =
- Backend running locally: `/verify-api` GREEN (OpenAPI /usage ↔ UsageInfo Codable in sync).
- `xcodebuild build -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` clean (use ios-tester agent).
- [HUMAN] live-sandbox leg (StoreKit sandbox can't be driven headless): via ios-ui-driver + founder, purchase the sub in RC sandbox → the immediate next question is served with no 429 after /entitlements/sync. Record the result pass/fail explicitly; if a real RS-NN is assigned, run it. The autonomous loop must HALT here and hand this leg to the founder — never fake-tick it.

Reviewed = n/a (exempt — see routing note). Commit + push (main, no deploy) once /verify-api + build are green. Tick Session E in ## Status + the parent iOS task lines. Report the [HUMAN] sandbox result explicitly (pass/fail), never silently.
```

---

## Status

`Done` = the session's `Done =` gate passed. `Reviewed` = maker≠checker adversarial review (`✅` passed · `⬜` pending · `n/a` non-payment/exempt). **A payment session's box may be ticked only when `Done = ✅` AND `Reviewed = ✅`.** A fresh context that reads `Done ✅ / Reviewed ⬜` knows the maker finished but the review has not passed — it must run the review, not treat the session as shippable.

| Session | Done | Reviewed | Box |
|---|---|---|---|
| 0 · [HUMAN] provisioning | 🔶 ASC done 2026-07-10 (agent via ASC API; all 3 products READY_TO_SUBMIT, prices €4.99/€29.99/€1.99 verified, review screenshot = Pencil mock `NEW_Screen/Paywall-Subscription`); RevenueCat + Fly secrets PENDING founder (no RC account/key exists) | n/a | ⬜ |
| A-schema · ORM + migration `0005` + seed | ⬜ | n/a | ⬜ |
| A-helper · `subscription_state` + tests | ⬜ | ⬜ | ⬜ |
| B · Entitlement gate | ⬜ | ⬜ | ⬜ |
| C · Webhook + sync | ⬜ | ⬜ | ⬜ |
| D · Account keying | ⬜ | ⬜ | ⬜ |
| E · iOS | ⬜ | n/a | ⬜ |

> As sessions land, note any symbol a later session imports here — e.g. *"Session A delivered `app/usage/subscription_state.py` → `apply_subscription_event`, `merge_subscription_rows` (Sessions C, D import these)."*
