# #93 — Subscription IAP + balíčky otázok + free-tier sizing

**Triage:** monetization · ready-for-human
**Status:** ready (prep complete — split into `issue-93-execution-prompts.md`)
**Created:** 2026-07-08
**Reversibility:** class b — payments/monetization → ready-for-human (Ralph nikdy)

## Why

Founder prompt (2026-07-08, raw):

> Pridať subscription-based in-app purchases. Potrebný research, ako najlepšie nastaviť používanie balíčkov (question packs) spolu s pravidelným subscription. 100 otázok mesačne vo free tieri je príliš veľa — mnohým používateľom by to stačilo a nikdy by nekúpili. Pocitovo 20–30 otázok = plnohodnotnejší kvíz; v podnikoch býva ~50 otázok na kvíz → úplné maximum 50 free otázok/mesiac. DÔLEŽITÉ: tieto odhady závisia od reálnych nákladov na používateľa (mesačne pri x/y počte otázok). Hlavná obava: cena ElevenLabs TTS. Samotné generovanie otázok je lacné, lebo otázky sa zdieľajú medzi používateľmi.

Kontext: freemium 100 otázok/mesiac bolo rozhodnuté 2026-07-07 — týmto issue sa reviduje na základe cost-modelu.

## Research (Phase 1)

Gated web pass RAN (justified: external unknowns — ElevenLabs pricing, App Store subscription+consumable coexistence rules — plus explicit founder request for cost/prior-art research).

### Cost model
Full workflow → [`docs/research/issue-93-cost-model-2026-07-08.md`](../research/issue-93-cost-model-2026-07-08.md).
- Founder's "ElevenLabs TTS" fear is misaimed: ElevenLabs = STT; TTS runs on OpenAI and is **cached + shared across all users** (SHA256 on disk) → marginal TTS ≈ **$0/user**.
- Real variable cost ≈ **$0.0008/answer** (ElevenLabs STT ~$0.0007 + gpt-4o-mini parse/eval ~$0.0001).
- 1 free user/month: 20 Q → $0.016 · 50 Q → $0.04 · 100 Q (today's policy) → $0.08.
- Heavy payer 1 000 Q/mo ≈ $0.80; at €3.99 (net ~$3.02) break-even ~3 800 Q/mo — no real user threatens margin. Watch STT *minutes*, not TTS.

### Current code state
- **Quota:** `FREE_MONTHLY_LIMIT=100`, UTC-calendar-month window (`app/usage/tracker.py:29,59-95`); implicit reset (`_next_reset` tracker.py:40-45).
- **Storage:** `DailyUsage` row per `(subject_id, UTC day)`, cols `questions_count`, `is_premium` (`app/db/models.py:142-155`).
- **Enforcement:** start-gate HTTP 429 `quota_limit_reached` (`app/api/routes/quiz.py:60-76,147-148`) + per-answer check → FINISHED (`app/quiz/flow.py:245-286`); iOS 429→paywall (`Services/NetworkService.swift:229-232`, `ViewModels/QuizViewModel.swift:538-540`).
- **Auth:** two-tier — `AnonymousIdentity` (App Attest) + `User` (`apple_sub` anchor, #61); JWT `sub` → `session.user_id`. **No `plan_tier`** by design (F8); premium lives *only* on `daily_usage.is_premium`.
- **StoreKit:** iOS client complete (StoreKit 2, `Services/StoreManager.swift`, product `com.carquiz.unlimited` — a **non-consumable**, not a sub; `PurchaseService.swift`, `Views/PaywallView.swift`). **Backend has no receipt/JWS verification** — only admin-key `POST /usage/{id}/premium` (`app/api/routes/misc.py:76-93`) sets premium; `notifyPremiumPurchased` just re-fetches `/usage` → entitlement stays client-local. **This gap is the core of the feature.**
- **DB:** Postgres + Alembic (`alembic/versions/0001..0004`); no subscription/expiry/receipt/ledger tables — all net-new.

### Prior-art / build-vs-adopt
- **App Store rules — coexistence OK:** sub + consumable "packs" is sanctioned; Guideline 3.1.2 says subs "may be offered alongside à la carte offerings" incl. consumable credits ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)). Constraint: the **sub must deliver ongoing value**, not a one-off unlock — the common 3.1.2 rejection ([RevenueCat](https://community.revenuecat.com/general-questions-7/app-review-rejection-guideline-3-1-2-ongoing-value-6617)). Unlimited-questions sub qualifies.
- **Recommendation — adopt RevenueCat now** (iOS-only, single founder): free to **$2,500 MTR** then ~1% gross; REST API + webhooks fit FastAPI; collapses receipt-validation + entitlement sync + webhook into the backend, freeing attention for the product ([Pricing](https://www.revenuecat.com/pricing)). Native StoreKit 2 stays viable later — Apple ships an official [Python lib](https://github.com/apple/app-store-server-library-python) for Server Notifications V2 — so migrating post-$2.5k is a cost decision, not forced.
- **Pattern shortlist (metered-AI apps):** **(B) sub = monthly credit grant that resets + packs top up** — recommended; caps COGS, matches current model ([Descript](https://help.descript.com/hc/en-us/articles/40053604160909-Top-Ups-Buy-Additional-Media-Minutes-and-AI-Credits)). (A) sub = unlimited + packs for non-subs → unbounded per-user cost, only with hard rate-limit. (C) packs-only → no recurring revenue, skip.
- **Consumable pitfalls:** no StoreKit restore + no Family Sharing → **balance ledger MUST live server-side** keyed to account, or reinstall wipes credits ([Apple](https://developer.apple.com/documentation/StoreKit/offering-completing-and-restoring-in-app-purchases)); handle REFUND/CONSUMPTION_REQUEST to claw back. Rollover **not required** (norm: monthly reset; purchased top-ups persist longer, e.g. up to 1yr).

### Market benchmarks
- **Trivia norm** = unlimited-but-ad-gated, low ad-removal sub $3–5/mo or one-time unlock (Trivia Crack 2 VIP $4.99/mo, $39.99/yr) — a hard 100-Q/mo cap is *more* generous than ad-gated but framed as an AI-cost budget ([App Store](https://apps.apple.com/us/app/trivia-crack-no-ads/id723795263)).
- **Metered-AI anchor** $9.99–$12.99/mo with small free refill then hard-stop/packs (Voice.ai free 5k credits, paid $12/mo) ([Voice.ai](https://voice.ai/pricing)); pack anchor +100 Q for $1.99–2.99 fits voice-app overage norms.
- **Conversion reality (plan low):** freemium median Day-35 ~2.1% vs hard-paywall ~10.7%; Games-Trivia ~5.2% ([RevenueCat 2026](https://www.revenuecat.com/state-of-subscription-apps/)).
- **Session smell test:** 20–30 Q ≈ 2–3 rounds/~20–30 min (one drive), below a full 30–50-Q pub night → 100 free/mo ≈ 3–5 sessions ([Wikipedia](https://en.wikipedia.org/wiki/Pub_quiz)).

### Open product questions (for founder)
- **Free-tier size:** cost data shows 100 Q/mo costs only ~$0.08/user — so the cap is a *conversion* lever, not a cost one. Keep 100, or cut to 20–30 (founder's "fuller quiz" instinct) / 50 (pub-quiz max) to push conversion?
- **Hybrid model:** sub = truly *unlimited*, or sub = large monthly *credit grant + packs* (pattern B, caps COGS)?
- **Price points:** monthly sub (~€4.99–9.99 band?), annual, and per-pack price (+100 Q for ~€1.99–2.99?).
- **Packs for non-subscribers:** can a free user buy a pack without subscribing, or are packs sub-only top-ups?
- **Rollover semantics:** do unused monthly credits reset (norm) or carry over? Do *purchased* packs persist longer / never expire?

## Resolved product decisions (founder, 2026-07-08)

- **Free tier → 30 questions / calendar month** (down from 100). Cost is negligible at any size; the cap is a *conversion* lever. 30 ≈ one full quiz session/drive.
- **Model = subscription grants UNLIMITED questions** (not a credit grant). Cost model supports it (heavy-user break-even ~3,800 Q/mo). Packs are a **separate purchase path for non-subscribers**.
- **Question packs:** buyable by **free users without a subscription** (e.g. +100 questions for ~€1.99), **never expire**. Monthly free allotment still resets each calendar month. Consumable → **server-side ledger keyed to account** (no StoreKit restore for consumables).
- **Price:** **€4.99 / month**, annual ~**€29.99/yr** (~50% vs 12×). Locked — cost model confirms comfortable margin.
- **Tiering:** **ONE paid tier in v1** ("Unlimited"). Entitlement/data model must be **forward-compatible for multiple tiers/products later** (family/multiplayer post-MVP) — no hardcoded `is_premium` boolean; model products + entitlements properly.
- **Build-vs-adopt:** adopt **RevenueCat** (free to $2,500 MTR, REST + webhooks fit FastAPI); backend gains server-side entitlement + purchase verification (today entitlement is client-only — the core gap this issue closes).

## Scope

**In scope**
- Free tier `FREE_MONTHLY_LIMIT` 100 → **30** / UTC-calendar-month (window logic unchanged).
- **RevenueCat** integration: iOS RevenueCat SDK (StoreKit products behind its offerings) + backend webhook endpoint that syncs subscription state & consumable grants.
- **Unlimited subscription** entitlement (€4.99/mo, €29.99/yr) — server-side source of truth.
- **Consumable question-pack** purchase (+100 Q ~€1.99, never expires) + **server-side credit ledger**.
- Backend **server-side entitlement** model replacing client-only `is_premium`; quota gate reads it.
- Paywall / upgrade UX: PaywallView driven by RevenueCat offerings; "buy pack" path for free users.

**Out of scope (explicit)**
- Multiple paid tiers — v1 ships ONE tier; only the *data model* is forward-compatible (no engine).
- Multiplayer / family sharing / gifting.
- Android & web clients (iOS-only; RevenueCat keeps a later cross-platform move cheap).
- Native StoreKit 2 server receipt validation (RevenueCat owns it until >$2.5k MTR; migration is a later cost decision, not this issue).

## Design

> Class **b** (payments) → lands **ready-for-human**; **Ralph never runs it**. Postgres + Alembic, head = `0004` → new revision `0005`.

### 1. Entitlement model (server-side, forward-compatible)
Today premium is a first-order hack: `daily_usage.is_premium` boolean read off the subject's most-recent daily row (`tracker.py:76-84`), settable only via admin-key `POST /usage/{id}/premium` (`misc.py:76-93`) — client-local, no product concept, no expiry, no per-account anchor. Replace with three small tables (net-new, no data to migrate — prod is founder-only):

- **`product`** — catalog row per RevenueCat product/entitlement id. Cols: `product_id` (PK, RC identifier), `kind` (`subscription`|`consumable`), `tier` (`unlimited`; the forward-compat seam — a new tier is a new row, never a code branch), `credit_amount` (nullable; 100 for a pack). Seeded, read-only at runtime.
- **`subscription`** — one active-sub projection per **account**. Cols: `account_id` (**PK / UNIQUE** — enforces exactly one row per account and is the webhook upsert's `ON CONFLICT` target; it is the durable account id the anon→sign-in fold re-keys to, so max-wins/revoke can't fork into duplicate ambiguous rows), `product_id`, `status` (`active`|`grace`|`expired`), `expires_at` (for `grace`, = the grace-period end), `rc_original_txn_id`, `last_event_ts_ms` (bigint nullable — per-event ordering watermark; see guard), `updated_at`. **Entitled** = `status ∈ {active, grace} AND expires_at > now()` (grace = Apple billing-retry window, still entitled — flaw fix 2). Mirrored from webhooks *and* the sync REST pull, so the hot path never calls RC.
  - **Two event classes (flaw fix 3 — revocation must be able to move `expires_at` backward / flip `expired`).** *Extend* events (`INITIAL_PURCHASE`, `RENEWAL`, upgrade/crossgrade `PRODUCT_CHANGE`, `UNCANCELLATION`) only ever push expiry forward. *Revoke* events (`REFUND`, `CHARGEBACK`/dispute, `EXPIRATION`, immediate-revoke `CANCELLATION`, downgrade `PRODUCT_CHANGE`) must **shorten** `expires_at` or set `status=expired`. A pure max-wins-on-`expires_at` guard structurally cannot apply a revoke (a refund moves expiry *backward* or leaves it equal with status→expired — both dropped by max-wins), which would let a refunded annual sub keep unlimited for the remaining ~11 months. So max-wins alone is wrong.
  - **Ordering guard = per-event watermark `last_event_ts_ms` (webhook), restored from c1.** Every RC webhook carries `event_timestamp_ms`. Apply **any** webhook event (extend *or* revoke) **iff `event_timestamp_ms > last_event_ts_ms`**, then set `last_event_ts_ms = event_timestamp_ms`. Within an applied event: *extend* uses **max-wins on `expires_at`** (status precedence `active>grace>expired` on ties); *revoke* **writes** the shortened `expires_at` / `status=expired` from the event. This defeats stale/replayed events in **both** directions — an out-of-order older RENEWAL can't re-extend a since-refunded sub (its `event_timestamp_ms ≤ last_event_ts_ms` → dropped), and a genuine newer REFUND *does* revoke.
  - **`/entitlements/sync` = full-state reconcile, not an event.** The REST `GET /subscribers/{id}` returns RC's **current authoritative snapshot** (no `event_timestamp_ms`). Sync **overwrites** the local `status`/`expires_at` to match RC's current truth directly (bypassing the per-event guard — an idempotent overwrite of current truth cannot double-apply), then sets `last_event_ts_ms = the snapshot's `request_date_ms`` (RC's own clock at snapshot generation). Convergence: every event RC already folded into the snapshot has `event_timestamp_ms ≤ request_date_ms` → later-arriving webhook for it is dropped (already reflected); only a genuinely newer webhook (`> request_date_ms`) applies. So a refunded sub can never be resurrected by a stale replay, and sync-vs-webhook ordering is total in both directions.
- **`credit_ledger`** — append-only. Cols: `id`, `account_id`, `delta` (+100 grant / −1 consume / −100 refund clawback), `kind` (`grant`|`consume`|`clawback`), `reason`, `store_txn_id` (nullable — the **store transaction id**, present in BOTH the webhook `transaction_id` and the REST `non_subscriptions[].store_transaction_id`), `rc_event_id` (nullable — RC per-event id, webhook-only), `created_at`. **Split idempotency (flaw fix 1):** two *partial* unique indexes — `UNIQUE(store_txn_id) WHERE kind='grant'` and `UNIQUE(rc_event_id) WHERE kind='clawback'`. A pack GRANT dedupes on the **store txn id**, so it applies exactly once whether it arrives first via `/entitlements/sync` (REST, no event id) or via the `NON_RENEWING_PURCHASE` webhook — both carry the same store txn id. A CLAWBACK is event-driven (RC always delivers REFUND/CANCELLATION with an event id) and dedupes on `rc_event_id`; it shares the grant's `store_txn_id` (same purchase) but the partial indexes are disjoint by `kind`, so grant and clawback never collide. The grant index is **global, not per-account**, so anon→sign-in re-keying (below) only rewrites `account_id` and a post-sign-in webhook for the same txn still no-ops. **Balance = SUM(delta)**; source of truth for consumables (no StoreKit restore).

**Pinned RC / App Store identifiers** (seed migration `0005` and iOS offerings both hardcode these; the `com.carquiz.*` convention matches the retired non-consumable):
- Entitlement id: **`unlimited`**
- Subscription products: **`com.carquiz.unlimited.monthly`** (€4.99), **`com.carquiz.unlimited.annual`** (€29.99) — one RC subscription group.
- Consumable pack: **`com.carquiz.pack.questions100`** (+100 Q, `credit_amount=100`).

⚠️ **Human prerequisite (founder, class-b gate):** these product ids + the `unlimited` entitlement must be **created in App Store Connect and RevenueCat before** the seed/offerings ship — code references them by the exact strings above but cannot create them. Nothing in this issue provisions the console.

**Account keying (respects existing auth).** Entitlement keys to the **durable account**, not the ephemeral device subject. When signed in (`User.apple_sub`, #61) `account_id` = the user id; while anonymous (`AnonymousIdentity`) it = the anon subject. The #61 anon→user upgrade already folds `daily_usage` rows into the user (`models.py:158-168`); this issue **extends that same fold** to re-key `subscription` + `credit_ledger` rows so a pack bought while anonymous survives sign-in. RC `app_user_id` is set to the same durable id and RC's `logIn` alias is called on upgrade so RC's own history merges too. *(Judgment call — see return note: a pack bought anonymously then not signed in stays on the anon subject, so a device reinstall before sign-in loses it; sign-in is the durability boundary and the paywall should nudge it.)*

**Subscription fold = MERGE, not a bare re-key (fold-collision fix).** `subscription.account_id` is PK/UNIQUE (one row per account), so a naïve "UPDATE … SET account_id = user_id" **aborts on the UNIQUE constraint** whenever a user-keyed row already exists — the realistic path: user subscribes on Device A (signed in → user-keyed row) then restores on a fresh anon install on Device B (webhook writes an anon-keyed row); at sign-in the anon row's re-key collides. The fold therefore **merges into one row keyed to the durable user account, under the exact rules the webhook uses**: keep **max-wins on `expires_at`**, **status precedence `active>grace>expired`** on ties, and the **larger `last_event_ts_ms`**; then **delete the anon row** — all inside the sign-in transaction so it is atomic and can never leave two rows or abort. *(Merge is **row-wise**, not field-wise: the winner is the whole row with the greater `expires_at` (taken as one unit, keeping its status), with only `last_event_ts_ms` resolved as a field-max — so the merge can never synthesize a `{status, expires_at}` combination that neither source row held.)* When only the anon row exists (common case) it degrades to a plain re-key UPDATE. The `credit_ledger` fold stays a bare re-key of `account_id`: it is **collision-free by construction** — the grant/clawback unique indexes are **global on the store/event ids, not per-account**, and the ledger is append-only, so re-keying rows to the user account can never violate a uniqueness constraint (a post-sign-in webhook for the same txn still no-ops on the global index). This `subscription`-only asymmetry is intentional, not an oversight.

### 2. RevenueCat integration shape
- **iOS:** RevenueCat SDK replaces the hand-rolled StoreKit stack (`StoreManager.swift`, `PurchaseService.swift`); the old `com.carquiz.unlimited` **non-consumable** is retired (never shipped to a real buyer — memory: prod founder-only). Offerings = 1 auto-renewing subscription (monthly + annual) + 1 consumable pack product. `PaywallView` renders `Offerings`; purchase & "restore purchases" (subscription only) go through the SDK. Configure with `app_user_id` = durable account id.
- **Backend owns** the consumable **credit ledger** and the **quota gate**; **RevenueCat owns** receipt/JWS validation and subscription lifecycle. New endpoint **`POST /webhooks/revenuecat`**: verify authenticity via the shared-secret **`Authorization` header** RC sends (constant-time compare; reject 401 otherwise) *before* parsing. Event handling:
  - Every event is gated by **`event_timestamp_ms > last_event_ts_ms`** first (else no-op, stale/replayed); on apply, `last_event_ts_ms` advances to the event's ts.
  - **Extend** — `INITIAL_PURCHASE`/`RENEWAL`/upgrade `PRODUCT_CHANGE`/`UNCANCELLATION` → upsert `subscription` (status=active, `expires_at` from `expiration_at_ms`) with **max-wins on `expires_at`** (equal-expiry ties → status precedence `active>grace>expired`).
  - **Revoke** — `REFUND`/`CHARGEBACK`/immediate `CANCELLATION`/downgrade `PRODUCT_CHANGE` → **write** the event's (possibly *earlier*) `expires_at`, or `status=expired` when RC signals immediate revocation; `EXPIRATION` → `status=expired`. These bypass max-wins (that is the point — a refund legitimately moves expiry backward) but are still protected by the `last_event_ts_ms` watermark, so only a genuinely newer revocation lands (flaw fix 3). A *deferred* `CANCELLATION` (Apple keeps the user entitled until period end) instead leaves `expires_at` unchanged, status stays active — the natural `EXPIRATION` later flips it.
  - `BILLING_ISSUE` → status=`grace`, `expires_at` = grace-period end (`grace_period_expiration_at_ms`); the subscriber **stays entitled** through the retry window (flaw fix 2).
  - `NON_RENEWING_PURCHASE` (pack) → insert `+credit_amount` grant (`kind='grant'`, `store_txn_id` = event `transaction_id`, `rc_event_id` = event id); dedupe is on `store_txn_id`.
  - `REFUND`/`CANCELLATION` of a pack → insert clawback (`kind='clawback'`, `−credit_amount`, `rc_event_id` = the **refund event's** own id, `store_txn_id` = the **original** purchase txn); a redelivered refund hits `UNIQUE(rc_event_id) WHERE kind='clawback'` → no-op, so clawback applies exactly once and a refunded user loses the credits. `CONSUMPTION_REQUEST` → report balance/consumed to RC.
- Hot path never calls RC (latency + outage isolation); the webhook-mirrored local tables are read instead.

**Purchase→webhook propagation bridge (closes the "just paid, still 429'd" window).** RC webhooks are the durable mirror but land seconds-to-minutes after purchase; a user who just subscribed/bought a pack would otherwise hit the gate with no local row and get 429'd. Bridge: immediately after a successful SDK purchase, iOS calls a new authenticated **`POST /entitlements/sync`**; the backend does a **one-shot pull** of `GET /subscribers/{app_user_id}` from the RevenueCat **REST API** (server-side secret key). **Subscription** state is a **full-state reconcile**: overwrite local `status`/`expires_at` from `subscriptions[pid]` (`expires_date`→`expires_at`; `grace_period_expires_date`/`billing_issues_detected_at`→`grace`; no active/expired entry → `expired`) to RC's current truth, and set `last_event_ts_ms = request_date_ms` (RC's snapshot clock). Because the snapshot is authoritative current truth, this idempotent overwrite converges with webhooks in both directions — a later webhook already reflected in the snapshot has `event_timestamp_ms ≤ request_date_ms` and is dropped, only a strictly-newer one applies — so a purchase, a renewal, **and a refund** all reconcile without a stale replay resurrecting a revoked sub. **Pack** grants come from `non_subscriptions[pid][]` (`store_transaction_id`→`store_txn_id`, `kind='grant'`) and dedupe on the **store txn id**, so the later `NON_RENEWING_PURCHASE` webhook for the same purchase is a guaranteed no-op (sync carries no `event.id`, so a per-event grant key would double-grant). This is the only place the request path touches RC, and it is off the quiz hot path (post-purchase, not per-question). No optimistic client-trust unlock — entitlement still derives solely from server-verified RC state.

### 3. Quota + entitlement enforcement flow
Consolidate the decision in the **usage/entitlement layer** (extend `UsageTracker` / a thin `EntitlementService` it calls) so both the start-gate (`quiz.py:60-76,147-148`) and the per-answer check (`flow.py:245-286`) share **one** path — no divergent gates. The codebase's existing **check(non-mutating) → record(mutating)** split is preserved exactly: `check_limit` never writes, and the single consume point stays inside `record_question`, which today is called only *after* the served question is secured (`quiz.py:148`, `flow.py:286`). This matters because question retrieval can 500 *before* record (`quiz.py:96`) — folding a debit into `check_limit` would burn a paid credit for a question that never gets served.

**`check_limit(account_id)` — NON-MUTATING.** Resolves the serving path in strict order and returns `(allowed, remaining, resets_at)` (unchanged signature) plus the resolved path; performs **no writes**:
1. **Entitled subscription?** (`status ∈ {active, grace} AND expires_at>now`) → allow, unlimited (`-1`). Grace = Apple billing-retry window; a `BILLING_ISSUE→grace` subscriber is still paying and must **not** fall through to the free allotment and get 429'd (flaw fix 2).
2. Else **free allotment**: monthly count < 30 → allow.
3. Else **pack credits**: balance (`SUM(delta)`) > 0 → allow.
4. Else deny → **429 `quota_limit_reached`** → iOS paywall (`NetworkService.swift:229-232`).

**`record_question(account_id)` — MUTATING, the single consume point.** Called exactly once per *served* question, it **re-derives** the same order atomically and applies exactly **one** effect, symmetric across paths:
- Entitled (`status ∈ {active, grace}`, `expires_at>now`) → insert the visible row, **no counter increment, no debit** (unlimited).
- Free (count < 30) → increment the monthly counter (today's atomic upsert, unchanged).
- Else → **debit one credit** via a single guarded write (`INSERT … WHERE (SELECT SUM(delta)…) > 0` in one transaction).

So one served question = exactly one accounted unit on whichever path serves it — no asymmetric double-accounting, and a pre-record 500 debits nothing.

**No-regression on #89/#90:** the entitlement read **defaults deny** in *both* `check_limit` and `record_question` — a null/absent `account_id` yields no subscription and zero balance and no debit (never a bypass; #89 was exactly a null-subject bypass). Each mutating effect in `record_question` is a single atomic guarded write, not read-then-write, and `record_question` re-derives the path independently of `check_limit`, so a check→record race can't double-spend a credit (preserves the #90 TOCTOU fix).

### 4. Consumable pack correctness
- Ledger is the **only** source of truth (Apple does not restore consumables; balance must not live on device).
- **Split idempotent grant + clawback:** GRANT rows dedupe on **`store_txn_id`** (`UNIQUE … WHERE kind='grant'`) — the store transaction id carried by *both* the webhook (`transaction_id`) and the REST subscriber payload (`non_subscriptions[].store_transaction_id`), so a pack grants exactly once whether the sync pull or the webhook lands first. CLAWBACK rows dedupe on **`rc_event_id`** (`UNIQUE … WHERE kind='clawback'`), which RC always supplies for refund events. Grant and clawback share the same `store_txn_id` but the partial indexes are disjoint by `kind`, so they never collide and each applies exactly once.
- **Clawback:** REFUND / pack-CANCELLATION inserts a negative row (`kind='clawback'`, its own `rc_event_id`, the original `store_txn_id`); if already spent the balance goes negative and the gate treats `≤0` as "no credits" (user can't consume until positive again — acceptable, no reconciliation engine).
- Consumption is a ledger debit (reason=`consume`), so audit = replaying the append-only log.

### 5. Migration / rollout
- **Existing `is_premium` users:** none in prod (founder-only). Migration `0005` creates the three tables and seeds `product`; it does **not** backfill `is_premium` (no rows worth migrating). The column is left in place but no longer read by the gate; drop it in a later cleanup.
- **100→30:** change the `FREE_MONTHLY_LIMIT` default; the UTC-calendar-month window and implicit reset (`tracker.py:36-45`) are untouched. Interaction to note: a user already over 30 this month is immediately capped mid-month — acceptable for a founder-only prod, and the reset is still the 1st.
- **Backward-compat:** the `/usage` response only **adds** fields (subscription status, credit balance) — never removes — so an un-updated client keeps working (it just sees the new 30 cap and no pack UI). Old clients can't reach the new entitlement, but there are no old paid clients.

### 6. Reversibility & class
Class **b — payments/monetization.** Every task lands **ready-for-human review**; the Ralph loop must **never** execute this issue. Reversible pieces (the 30-cap constant, table adds) are low-risk; the RC keys/webhook secret and App Store product config are founder-gated manual steps.

## Resolved design decisions

| Decision | Rationale |
|---|---|
| **Adopt RevenueCat** (not native StoreKit server validation) | Collapses receipt validation + entitlement sync + webhooks into one SDK; free to $2.5k MTR; REST+webhooks fit FastAPI; solo founder. Native stays viable later via Apple's Python lib — migration is a cost decision, not forced ([RevenueCat pricing](https://www.revenuecat.com/pricing)). |
| **Entitlement = tables, not a boolean** | Founder locked forward-compat for multiple tiers/family later; `product`+`subscription`+`credit_ledger` grow to N tiers by adding rows, with zero speculative billing engine now. |
| **Server-side credit ledger** (append-only, balance=SUM) | Apple offers **no restore** for consumables + no Family Sharing → device-local balance is wiped on reinstall; ledger keyed to account is Apple's own recommendation ([Apple IAP](https://developer.apple.com/documentation/StoreKit/offering-completing-and-restoring-in-app-purchases)). Append-only = free audit + trivial clawback. |
| **Split ledger idempotency: GRANT `UNIQUE(store_txn_id)`, CLAWBACK `UNIQUE(rc_event_id)`** (partial, disjoint by `kind`) | A pack grant can land first via `/entitlements/sync` (RC REST — carries `store_transaction_id` but **no** `event.id`) or via the `NON_RENEWING_PURCHASE` webhook (carries both). Deduping grants on the **store txn id** (present in both) makes them exactly-once across *either* source, killing the double-grant a per-event key would allow (sync id ≠ webhook id → both would insert +100). Clawbacks are event-only → dedupe on `rc_event_id`; disjoint-`kind` partial indexes stop grant/clawback colliding despite sharing the txn id. Grant index is global (not per-account), keeping anon→sign-in re-keying safe. |
| **Purchase→webhook bridge: `POST /entitlements/sync`** | Webhooks land seconds-to-minutes after purchase, so a just-paid user would be 429'd until the mirror catches up. iOS calls sync post-purchase; backend pulls RC REST `GET /subscribers/{id}` once and upserts through the same idempotent/monotonic apply path. Off the quiz hot path; no client-trust optimistic unlock. |
| **Pinned RC identifiers** (`unlimited` entitlement; `com.carquiz.unlimited.monthly`/`.annual`; `com.carquiz.pack.questions100`) | Seed `0005` + iOS offerings hardcode exact strings, so they must be named in the plan, not deferred. Founder must create them in App Store Connect + RevenueCat first (class-b human prerequisite). |
| **Extend-vs-revoke split + per-event `last_event_ts_ms` ordering; `/entitlements/sync` as full-state snapshot reconcile** | Pure max-wins-on-`expires_at` structurally *can't revoke*: a `REFUND`/`CHARGEBACK` moves expiry backward or ties with status→expired — both dropped — so a refunded annual sub would keep unlimited ~11 months. Fix: classify events — *extend* (`INITIAL_PURCHASE`/`RENEWAL`/upgrade `PRODUCT_CHANGE`/`UNCANCELLATION`) does max-wins; *revoke* (`REFUND`/`CHARGEBACK`/immediate `CANCELLATION`/downgrade `PRODUCT_CHANGE`/`EXPIRATION`) writes a shorter `expires_at`/`expired`. Order webhooks by RC's `event_timestamp_ms` watermark `last_event_ts_ms` (apply iff strictly newer) so stale replay can't wrongly extend *or* revoke. Sync REST snapshot has no event ts, so it **overwrites** `status`/`expires_at` to RC's current truth and sets `last_event_ts_ms = request_date_ms`; anything RC already folded in is ≤ that and dropped, only a strictly-newer webhook applies → refunded sub never resurrected, ordering total in both directions. |
| **`subscription.account_id` is PK/UNIQUE** | The webhook "upsert (max-wins/revoke)" needs an `ON CONFLICT` target and the hot path assumes exactly one active-sub projection per account. Without the constraint the upsert has no conflict key and can insert duplicate rows → ambiguous entitlement read. The key is the durable account id the anon→sign-in fold re-keys to. |
| **Anon→sign-in subscription fold = MERGE, not bare re-key** | Because `account_id` is PK/UNIQUE, a plain "UPDATE … SET account_id=user_id" **aborts on the UNIQUE constraint** when a user-keyed row already exists (sub on Device A + anon restore on Device B → two rows for one account at sign-in). The fold instead merges both into the user-keyed row under the **same webhook rules** (max-wins `expires_at`, status `active>grace>expired` on ties, larger `last_event_ts_ms`) then deletes the anon row, atomically in the sign-in transaction — so it can never leave two rows or abort. Only-anon-row case degrades to a plain re-key. `credit_ledger` stays a bare re-key: collision-free by construction (grant/clawback unique indexes are **global**, not per-account; append-only) — the asymmetry is intentional, `subscription`-only. |
| **Grace counts as entitled (`status ∈ {active, grace}`)** | A `BILLING_ISSUE→grace` subscriber is inside Apple's billing-retry window and still considered subscribed; gating only on `active` would 429 a paying user mid-sub. The entitlement gate (both `check_limit` and `record_question`) accepts `active`\|`grace` with `expires_at>now` (grace's `expires_at` = grace-period end); an `EXPIRATION` past that exits to `expired`. |
| **Sub = unlimited (not a metered credit grant)** | Founder decision; cost model shows heavy-user break-even ~3,800 Q/mo at €4.99, so no realistic user is margin-negative ([cost model §3](../research/issue-93-cost-model-2026-07-08.md)). |
| **Gate lives in the usage/entitlement layer, checked sub→free→credits** | Single shared path for start-gate + per-answer avoids the divergent-gate class of bug; order puts the free "unlimited" case first (cheap boolean), spends paid credits only after the free allotment. |
| **Consume lives in `record_question`, not `check_limit`** | Keeps the codebase's check(non-mutating)→record(mutating) split: `check_limit` only reads the serving path; the single credit-debit/free-increment happens atomically in `record_question`, once per *served* question, symmetric across sub/free/credit. A pre-record 500 (`quiz.py:96`) debits nothing; no asymmetric double-accounting. |
| **Default-deny entitlement read + atomic credit debit** | Preserves #89 (null-subject) and #90 (TOCTOU) fixes: missing account never bypasses in either check or record; consume is one guarded write, and record re-derives the path independently so a check→record race can't double-spend. |

## Tasks (atomic)

**Prerequisite (human, class b)**
- [ ] **[HUMAN] Provision console + secrets.** Founder creates in App Store Connect + RevenueCat: the `unlimited` **entitlement**; products `com.carquiz.unlimited.monthly` (€4.99), `com.carquiz.unlimited.annual` (€29.99, one sub group), `com.carquiz.pack.questions100` (consumable, +100). Sets backend secrets `REVENUECAT_API_KEY` (REST) + `REVENUECAT_WEBHOOK_SECRET` (Fly). Blocks the seed + iOS offerings + webhook auth; nothing in code provisions these.

**DB & migration**
- [ ] **Add ORM models** `Product`, `Subscription`, `CreditLedger` to `app/db/models.py` (cols exactly per Design §1: `product.{product_id PK, kind, tier, credit_amount}`; `subscription.{account_id PK/UNIQUE, product_id, status, expires_at, rc_original_txn_id, last_event_ts_ms BIGINT NULL, updated_at}`; `credit_ledger.{id, account_id, delta, kind, reason, store_txn_id NULL, rc_event_id NULL, created_at}`). No `is_premium` change.
- [ ] **Migration `0005`** (`alembic/versions/0005_*`): create the 3 tables (head=`0004`) with `subscription.account_id` as **PK/UNIQUE** (the webhook upsert `ON CONFLICT` target); two partial unique indexes `UNIQUE(store_txn_id) WHERE kind='grant'` (global, not per-account) + `UNIQUE(rc_event_id) WHERE kind='clawback'`; seed `product` rows for the 3 pinned ids (`credit_amount=100` on the pack). Tables-only — NO `is_premium` backfill. Verify `upgrade`+`downgrade` on a scratch DB.

**Entitlement/quota backend**
- [ ] **`EntitlementService`** (new `app/usage/entitlement.py` or fold into `UsageTracker`): `is_entitled(account_id)` = `subscription.status ∈ {active,grace} AND expires_at>now()`; `credit_balance(account_id)` = `SUM(credit_ledger.delta)`. Both **non-mutating**, **default-deny** on null/absent `account_id` (preserve #89).
- [ ] **`FREE_MONTHLY_LIMIT` 100 → 30** in `app/usage/tracker.py:29`; window/reset logic (`tracker.py:36-45`) untouched.
- [ ] **Wire `check_limit`** (`tracker.py:59-95`, non-mutating) to resolve sub→free-30→credits→deny order (Design §3 steps 1-4), returning `(allowed, remaining, resets_at)` + resolved path. Stops reading `daily_usage.is_premium`.
- [ ] **Wire `record_question`** (single consume point, `flow.py:286`/`quiz.py:148`): re-derive path atomically, apply exactly one effect — entitled→row only, free→counter upsert, else→single guarded credit debit (`INSERT … WHERE (SELECT SUM(delta)…)>0`). Symmetric; #90 TOCTOU preserved.
- [ ] **Extend `/usage` response** (`app/api/routes/misc.py` / shared model) to ADD `subscription_status` + `credit_balance` (additive only, backward-compat). Update `packages/shared` Pydantic model.

**RevenueCat webhook + sync bridge**
- [ ] **`POST /webhooks/revenuecat`** (new `app/api/routes/webhooks.py`): verify shared-secret `Authorization` header (constant-time) **before parsing** → 401 else. Gate every event on `event_timestamp_ms > last_event_ts_ms` (else no-op), advance watermark on apply. **Watermark scoped to SUBSCRIPTION state only.** Upsert `subscription` with `ON CONFLICT(account_id)` (the PK/UNIQUE) as the merge target. Extend events (`INITIAL_PURCHASE`/`RENEWAL`/upgrade `PRODUCT_CHANGE`/`UNCANCELLATION`) → max-wins on `expires_at`; revoke (`REFUND`/`CHARGEBACK`/immediate `CANCELLATION`/downgrade `PRODUCT_CHANGE`) → write shorter `expires_at`/`status=expired`; `EXPIRATION`→expired; `BILLING_ISSUE`→grace (`grace_period_expiration_at_ms`). **Impl note (i): NULL-safe first-event watermark** — first webhook (watermark NULL) must apply, not be dropped by a NULL comparison.
- [ ] **Pack webhook handling** in same endpoint: `NON_RENEWING_PURCHASE` → `+credit_amount` grant (`store_txn_id`=`transaction_id`, `rc_event_id`=event id), dedupe on `store_txn_id`. **Impl note (ii): pack grants are NOT gated by the subscription watermark** — a pack purchase must grant even if its `event_timestamp_ms` ≤ the sub watermark; dedup is purely the partial unique index. `REFUND`/`CANCELLATION` of pack → clawback (`−credit_amount`, `rc_event_id`=refund event id, `store_txn_id`=original). `CONSUMPTION_REQUEST` → report balance to RC.
- [ ] **`POST /entitlements/sync`** (authenticated, in `webhooks.py`/new `entitlements.py`): one-shot RC REST `GET /subscribers/{app_user_id}`. Subscription = **full-state overwrite** of `status`/`expires_at` from `subscriptions[pid]`, set `last_event_ts_ms=request_date_ms` (bypasses per-event guard). Packs from `non_subscriptions[pid][]` → grants keyed on `store_transaction_id`, dedupe on `store_txn_id` (webhook for same purchase no-ops).

**Account keying**
- [ ] **Extend #61 anon→user fold** (`models.py:158-168`) on sign-in, inside the existing fold transaction. **`subscription` = MERGE, not bare re-key** (PK/UNIQUE on `account_id` → a re-key UPDATE aborts if a user-keyed row already exists): if both an anon-keyed and user-keyed row exist for the account, resolve into the user-keyed row with the **same webhook rules** (max-wins on `expires_at`, status precedence `active>grace>expired` on ties, larger `last_event_ts_ms`) then **delete the anon row**; if only the anon row exists, plain re-key UPDATE. **`credit_ledger` = bare re-key** of `account_id` (collision-free: grant/clawback unique indexes are global, ledger append-only — a post-sign-in webhook for the same txn still no-ops). Call RC `logIn`/alias so RC history merges.

**iOS StoreKit/RevenueCat + paywall**
- [ ] **Replace StoreKit stack with RevenueCat SDK** (`Services/StoreManager.swift`, `PurchaseService.swift`): configure `app_user_id`=durable account id; retire `com.carquiz.unlimited` non-consumable. Offerings = sub (monthly+annual) + consumable pack.
- [ ] **`PaywallView`** (`Views/PaywallView.swift`) renders RC `Offerings` (sub + "buy pack" path for free users); "restore purchases" = subscription only.
- [ ] **Update iOS `/usage` Codable** — add `subscription_status` + `credit_balance` to `UsageInfo` (`apps/ios-app/Hangs/Hangs/Models/UsageInfo.swift`, incl. its `CodingKeys`) to match the extended Pydantic model. **Ordered after** the `packages/shared` Pydantic change and **before** the `/verify-api` acceptance — without this `/verify-api` cannot be GREEN.
- [ ] **Post-purchase → `POST /entitlements/sync`** after any successful SDK purchase (before re-fetching `/usage`); 429→paywall path (`NetworkService.swift:229-232`, `QuizViewModel.swift:538-540`) unchanged.

**Tests**
- [ ] **Entitlement/quota pytest** (`apps/quiz-agent/tests/test_entitlement.py`): free cap 30; active + grace bypass; credit debit exactly-once per served question; pre-record retrieval-500 debits nothing (**integration-level via `flow.process_answer`/`/start` with a retriever mocked to raise after check, before record** — not a tracker unit test); default-deny on null account; **anon→sign-in subscription merge collides on nothing** (`test_anon_to_signin_merges_two_sub_rows` — both an anon- and user-keyed sub row → one merged user-keyed row, max-wins, no UNIQUE abort).
- [ ] **Webhook/ledger pytest** (mocked RC, `tests/test_webhooks.py`): grant idempotent across sync+webhook; refund revokes live sub; stale out-of-order RENEWAL can't re-extend refunded sub; **newer-than-sync RENEWAL (ts > `request_date_ms`) still applies after `/entitlements/sync`** (apply-direction convergence — watermark not too aggressive); NULL-safe first event; pack grant not gated by sub watermark; clawback once.
- [ ] **`/verify-api`** Codable↔Pydantic sync for the `/usage` additions.

## Acceptance

- [ ] Free user's 31st question this month is denied: `test_entitlement.py::test_free_cap_is_30` (429 `quota_limit_reached` at count 30, allowed at 29).
- [ ] Active subscriber bypasses cap: `test_entitlement.py::test_active_sub_unlimited`; grace subscriber also bypasses (`expires_at>now`): `::test_grace_sub_unlimited` (flaw fix 2).
- [ ] One served question = exactly one accounted unit; pack credit debits exactly once: `test_entitlement.py::test_credit_debit_once_per_served`.
- [ ] Pre-record retrieval 500 debits nothing — **integration-level**, driving the real call-site seam (record runs only after retrieval returns: `quiz.py:92-148` / `flow.py:267-286`), NOT the tracker in isolation (where check_limit never debits so it passes vacuously). `test_entitlement.py::test_pre_record_retrieval_500_no_debit`: a credit-holding account drives `flow.process_answer` (or `/start`) with the **retriever mocked to raise after `check_limit` but before `record_question`**; assert the credit ledger `SUM(delta)` is unchanged.
- [ ] Null/absent account never bypasses (default-deny #89) and check→record race can't double-spend (#90): `test_entitlement.py::test_null_account_denied`, `::test_no_double_spend`.
- [ ] Grant idempotent across sync + webhook (single +100, no double-grant): `test_webhooks.py::test_grant_idempotent_sync_then_webhook`.
- [ ] Refund revokes a live sub — `expires_at` shortened / `status=expired`: `test_webhooks.py::test_refund_revokes_active_sub`.
- [ ] Stale out-of-order RENEWAL (`event_timestamp_ms ≤ last_event_ts_ms`) cannot re-extend a refunded sub: `test_webhooks.py::test_stale_renewal_after_refund_noop`.
- [ ] **Convergence in the APPLY direction** — a genuinely-newer webhook arriving AFTER `/entitlements/sync` still applies (guards against a too-aggressive watermark silently swallowing a real renewal → paying subscriber loses access): `test_webhooks.py::test_newer_webhook_after_sync_applies`: call `/entitlements/sync` (sets `last_event_ts_ms=request_date_ms`), then deliver a RENEWAL with `event_timestamp_ms > request_date_ms`; assert it applies — `expires_at` advanced / entitlement retained.
- [ ] First webhook applies with NULL watermark (impl note i): `test_webhooks.py::test_first_event_null_watermark_applies`.
- [ ] Pack `NON_RENEWING_PURCHASE` grants even when its ts ≤ subscription watermark (impl note ii): `test_webhooks.py::test_pack_grant_not_gated_by_sub_watermark`.
- [ ] Clawback applies once; redelivered refund hits `UNIQUE(rc_event_id) WHERE kind='clawback'` → no-op: `test_webhooks.py::test_clawback_once`.
- [ ] Anon→sign-in preserves credits (ledger + subscription re-keyed, no double-grant on replay): `test_entitlement.py::test_anon_to_signin_preserves_credits`.
- [ ] Anon→sign-in **merges** two subscription rows without a UNIQUE violation: `test_entitlement.py::test_anon_to_signin_merges_two_sub_rows` — seed BOTH an anon-keyed and a user-keyed `subscription` row for one account with **different `expires_at`**, run the fold, assert exactly **one** surviving row keyed to the user account carrying the **max-wins `expires_at`**, winning `status` (`active>grace>expired`) and larger `last_event_ts_ms`, and that the fold transaction did **not** abort / raise a UNIQUE violation.
- [ ] Webhook auth: missing/wrong `Authorization` → 401 before body parse; correct secret → 200. `test_webhooks.py::test_webhook_auth_rejects_bad_secret`.
- [ ] Migration `0005` up+down clean on scratch DB and seeds 3 products: `alembic upgrade head` then `downgrade -1`; `SELECT count(*) FROM product` = 3; both partial indexes present (`\d+ credit_ledger`).
- [ ] `/usage` response gains `subscription_status` + `credit_balance`, removes nothing; OpenAPI ↔ iOS Codable in sync: `/verify-api` GREEN.
- [ ] Live end-to-end purchase→entitlement (sim, RC sandbox): purchase sub, immediate next question served (no 429) after `/entitlements/sync` — RS to be assigned; **flag: sandbox purchase leg is manual/human-verified** (StoreKit sandbox can't be fully driven headless).

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND 0.78 |
| 4 · Impl-plan         | ✅ done | — |
| 5 · Impl-plan review  | ✅ done | ready-check READY · design-soundness SOUND 0.75 |
| 6 · Split             | ✅ done | 6 sessions → `issue-93-execution-prompts.md` |

**Last updated:** 2026-07-08 · **Prep COMPLETE.** All 6 phases green. Split into 1 human + 5 code sessions ([`issue-93-execution-prompts.md`](./issue-93-execution-prompts.md)). Class **b — payments** → `ready-for-human` (Ralph never). **Gate attempts:** P3 3/3 done (SOUND 0.78) · P5 3/3 done (SOUND 0.75).
