# Issue #95 — Custom quiz-pack ordering: client half ("Phase 4a lite")

**Triage:** feature · ready-for-agent (3 sessions + 1 deferred) — founder decisions locked 2026-07-12, see below

**Created:** 2026-07-11 · **Source:** founder report "nevidim nikde ui, kde by sa dal kupit balicek podla mojho zadania" → diagnosis workflow 2026-07-11

## Problem

The custom-pack backend (#33 Phase 1 order API + #36 Phase 2 real PackGenerator pipeline) is code-complete and deployed on Fly (`quiz-pack-api`), but the client half was deferred to "Phase 4a (#38)" which **was never opened**. Today:

- No iOS UI reaches `POST /v1/orders` (grep: zero references to /v1/orders or pack_10..50 in apps/ios-app).
- The order endpoint requires an `X-StoreKit-JWS` for product IDs `pack_10/20/30/50` that were **never created in App Store Connect**.
- Orders have no account linkage (idempotency on transaction_id only; GET by id unauthenticated Phase-1 style; no list-my-orders).
- The voice-quiz backend (`apps/quiz-agent`) has no `pack_id`-scoped session start — a delivered pack couldn't be played anyway (`questions.pack_id` column exists in pgvector, nothing filters on it).
- NOT to be confused with #93 "packs" (`com.carquiz.pack.questions100` = +100 quota credits from the shared corpus) — a different product already in PaywallView. Keep custom packs OUT of PaywallView to avoid concept collision.

## Plan (founder-first: prod is founder-only, payments last)

### Session 1 — backend reachability (quiz-pack-api) — **DONE 2026-07-12 (code + tests + DEPLOYED to prod, founder-approved)**
- ✅ Founder/dev order path: `X-Admin-Key` accepted in place of X-StoreKit-JWS on POST /v1/orders and /retry; admin transaction ids must be `admin-`-prefixed (can't squat a future real Apple tx id).
- ✅ Account linkage: order `user_id` set from an optional quiz-agent bearer JWT; `TokenService` promoted to `quiz_shared.auth` (quiz-agent re-exports — no fork); new `GET /v1/orders` (bearer-scoped "my orders", newest first). Phase-1 unauthenticated `GET /{id}` closed: admin key or owner bearer required (401 before 404 — no id probing).
- ✅ Cost capture (decision 5): `generation_orders.llm_cost_usd` (OpenRouter account-usage delta bracketing the run; NULL when unmeasurable — never a fabricated 0) + `search_cost_cents` (actual Tavily calls × credits; replaces the flat 1¢ estimate that missed ~30 per-question verification searches). Migration `4d8e2b7c1f0a`. Caveat: delta is account-wide for the window — fine founder-only, revisit before real users.
- ✅ Ops note documented in the orders router docstring (auto-suspend → first order after idle starts slow).
- ✅ **Deployed 2026-07-12 (founder approved "Nasaď všetko"):** migration `4d8e2b7c1f0a` applied + verified on prod DB; Fly secrets on quiz-pack-api: `AUTH_JWT_SECRET` (copied machine-to-machine from quiz-agent-api, value never left Fly), `OPENROUTER_API_KEY`, `LLM_GATEWAY=openrouter` (also un-degrades prod verification/scoring, cf. #53 note). Smoke-verified: /health 200, unauth GET 401, invalid bearer → 401 "Invalid bearer token" (proves the secret is set — unset would 503). Deploy command that works: `fly deploy -c apps/quiz-pack-api/fly.toml` **from repo root** (cwd = build context).

### Session 2 — iOS order flow
- Entry point OUTSIDE PaywallView (Home or Settings: "Create your own quiz pack").
- `OrderPackView`: prompt field (10–1000 chars, validated), optional category/theme, language picker en/sk/cs. No tier picker in v1 — fixed 30-question pack.
- Submit → `POST /v1/orders` → `OrderProgressView` polling `GET /v1/orders/{id}` at 1 Hz (skip SSE in v1 — the R4 polling fallback is already sanctioned in the #33 plan and is far less iOS work).

### Session 3 — play the pack
- quiz-agent session-start accepts optional `pack_id`; retriever filters on the existing pgvector `pack_id` column — deterministic filter, **no new LLM calls on the hot path**.
- iOS "My packs" list (from `GET /v1/orders?mine=1`) with "Start quiz" per delivered pack.
- Custom packs bypass the 30/mo free quota when played (decided — paid content).

### Session 4 — payments (DEFERRED until real users)
- App Store Connect consumable `com.carquiz.pack.custom.30` @ €3.99 (update `_PRODUCT_TIERS`), send `Transaction.jwsRepresentation` as X-StoreKit-JWS. Prereq: measured cost-per-pack from Session 1's cost capture confirms margin.

## Founder decisions (locked 2026-07-12)

1. **Tier set: single tier — 30 questions @ €3.99** (v1 has no tier picker; keep `_PRODUCT_TIERS` extensible, `pack_50` @ €5.99 is the planned later "road trip" upsell; drop pack_10/20). Research: `docs/research/custom-pack-size-pricing-2026-07-12.md` (session-length fit, ~$1.50–2.40 COGS/pack, margin at Apple price points). Session 4 product ID: `com.carquiz.pack.custom.30`.
2. **Custom packs bypass the 30/mo free quota** when played — paid content.
3. **Admin-gated order path stays founder-only** for now; subscription-perk question deferred until real users.
4. **Generate on the current pipeline now** despite the global #72 pause — founder-only risk; founder spot-checks the first pack.
5. Addendum (from research): **instrument cost capture** on the first founder order (total OpenRouter + Tavily spend per pack) — closes the #72 gap where no actual $/question was ever recorded; validates margin before Session 4 payments.

## References

- `docs/issues/issue-33-quiz-pack-api-phase-1.md` — order API + explicit Phase-4a deferral
- `docs/issues/issue-36-quiz-pack-api-phase-2.md` — real generation pipeline shipped 2026-05-28
- `docs/issues/issue-93-subscription-iap-packs.md` — the *other* pack concept (credit top-up)
- Diagnosis: workflow run wf_40420ee0-a61, 2026-07-11
