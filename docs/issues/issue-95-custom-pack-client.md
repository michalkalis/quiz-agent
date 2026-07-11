# Issue #95 — Custom quiz-pack ordering: client half ("Phase 4a lite")

**Triage:** feature · needs-founder-decisions → then ready-for-agent (3 sessions + 1 deferred)

**Created:** 2026-07-11 · **Source:** founder report "nevidim nikde ui, kde by sa dal kupit balicek podla mojho zadania" → diagnosis workflow 2026-07-11

## Problem

The custom-pack backend (#33 Phase 1 order API + #36 Phase 2 real PackGenerator pipeline) is code-complete and deployed on Fly (`quiz-pack-api`), but the client half was deferred to "Phase 4a (#38)" which **was never opened**. Today:

- No iOS UI reaches `POST /v1/orders` (grep: zero references to /v1/orders or pack_10..50 in apps/ios-app).
- The order endpoint requires an `X-StoreKit-JWS` for product IDs `pack_10/20/30/50` that were **never created in App Store Connect**.
- Orders have no account linkage (idempotency on transaction_id only; GET by id unauthenticated Phase-1 style; no list-my-orders).
- The voice-quiz backend (`apps/quiz-agent`) has no `pack_id`-scoped session start — a delivered pack couldn't be played anyway (`questions.pack_id` column exists in pgvector, nothing filters on it).
- NOT to be confused with #93 "packs" (`com.carquiz.pack.questions100` = +100 quota credits from the shared corpus) — a different product already in PaywallView. Keep custom packs OUT of PaywallView to avoid concept collision.

## Plan (founder-first: prod is founder-only, payments last)

### Session 1 — backend reachability (quiz-pack-api)
- Config-gated founder/dev order path: admin-key header accepted in place of X-StoreKit-JWS (reuse the existing `require_admin` dependency pattern).
- Account linkage: `account_id`/subject on `GenerationOrder`; `GET /v1/orders?mine=1` authenticated with the **same quiz-agent JWT/App-Attest identity from #61/#93** (reuse, don't fork, or orders stay orphaned). Also closes the Phase-1 unauthenticated-GET hole.
- Ops note: prod machines auto-suspend; first order after idle is slow — acceptable, document it.

### Session 2 — iOS order flow
- Entry point OUTSIDE PaywallView (Home or Settings: "Create your own quiz pack").
- `OrderPackView`: prompt field (10–1000 chars, validated), optional category/theme, language picker en/sk/cs, tier picker.
- Submit → `POST /v1/orders` → `OrderProgressView` polling `GET /v1/orders/{id}` at 1 Hz (skip SSE in v1 — the R4 polling fallback is already sanctioned in the #33 plan and is far less iOS work).

### Session 3 — play the pack
- quiz-agent session-start accepts optional `pack_id`; retriever filters on the existing pgvector `pack_id` column — deterministic filter, **no new LLM calls on the hot path**.
- iOS "My packs" list (from `GET /v1/orders?mine=1`) with "Start quiz" per delivered pack.
- Custom packs bypass the 30/mo free quota when played (recommended — paid content; confirm below).

### Session 4 — payments (DEFERRED until real users)
- App Store Connect / RevenueCat consumable products for the tiers (align naming, e.g. `com.carquiz.pack.custom.NN`; update `_PRODUCT_TIERS`), send `Transaction.jwsRepresentation` as X-StoreKit-JWS.

## Open product questions (founder, before Session 1)

1. Tier set: keep pack_10/20/30/50 or simplify (e.g. single 20-question tier for v1)?
2. Custom packs bypass the 30/mo free quota when played? (Recommended: yes.)
3. Admin-gated founder path stays founder-only, or becomes a subscription perk later?
4. Question generation is globally PAUSED pending the #72 quality review — OK to generate custom packs on the current pipeline, or wait for the quality bar? (First founder pack should be spot-checked either way.)

## References

- `docs/issues/issue-33-quiz-pack-api-phase-1.md` — order API + explicit Phase-4a deferral
- `docs/issues/issue-36-quiz-pack-api-phase-2.md` — real generation pipeline shipped 2026-05-28
- `docs/issues/issue-93-subscription-iap-packs.md` — the *other* pack concept (credit top-up)
- Diagnosis: workflow run wf_40420ee0-a61, 2026-07-11
