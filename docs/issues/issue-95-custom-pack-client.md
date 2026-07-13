# Issue #95 — Custom quiz-pack ordering: client half ("Phase 4a lite")

**Triage:** feature · ready-for-agent — **IN MVP via #96 phase P5 (founder re-confirmed 2026-07-13** after a brief same-day post-MVP detour). Sessions 2+3 execute as planned below; admin auth = Settings-entered key in Keychain (no key in binary); **fallback: if the e2e doesn't pass cleanly, hide the entry button and ship without it** (founder call). Proper end-user version (IAP-priced, regular users) = later follow-up; Session 4 payments stays deferred

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
- ✅ **Backend half DONE 2026-07-13 (`89d73f2`, deployed):** quiz-agent session-start accepts optional `pack_id`; retriever scopes to that pack (deterministic pgvector `pack_id` filter, **no hot-path LLM**) — drops the approved/difficulty/language constraints since delivered pack Qs stay `pending_review`; a normal session now filters `pack_id IS NULL` (no private-pack leak); custom-pack sessions bypass the 30/mo quota (paid content). 374 backend green + real-Postgres isolation proof.
- iOS "My packs" list (from `GET /v1/orders`, bearer-scoped) with "Start quiz" per delivered pack. **(iOS half — remaining.)**

### Session 4 — payments (DEFERRED until real users)
- App Store Connect consumable `com.carquiz.pack.custom.30` @ €3.99 (update `_PRODUCT_TIERS`), send `Transaction.jwsRepresentation` as X-StoreKit-JWS. Prereq: measured cost-per-pack from Session 1's cost capture confirms margin.

## Session 2+3 iOS client — execution recon (2026-07-13, 3-agent map; for the next session)

**Backend is DONE + deployed** (above). Remaining = the iOS client. Research is already done — the below IS the spec; **execute via a dynamic workflow** (fan out build + adversarial verify; keep raw file reads out of the main context).

**quiz-pack-api order contract** (host `quiz-pack-api.fly.dev` — a SEPARATE Fly app from quiz-agent-api):
- `POST /v1/orders` → 202 `{order_id, status, created_at}` (200 on idempotent replay, same shape). Headers: `X-Admin-Key` (founder path) **and** `Authorization: Bearer <jwt>` (links the order so it lists under "mine"). Body: `{transaction_id:"admin-<uuid>", product_id:"pack_30", prompt (10–1000 chars), language ("en"|"sk"|"cs"), target_count:30, category?, theme?}`. transaction_id MUST start `admin-`; product must be a `_PRODUCT_TIERS` key.
- `GET /v1/orders` → 200 `{orders:[OrderSnapshot]}` newest-first. **Bearer required, no admin-key alt** → send the signed-in bearer.
- `GET /v1/orders/{id}` → 200 `OrderSnapshot`. Bearer(owner) **or** `X-Admin-Key`. Poll 1 Hz until `status=="delivered"`, then play via `pack_id`.
- `OrderSnapshot` = `{order_id:uuid, status, product_id, target_count, language, category?, theme?, created_at, delivered_at?, pack_id:uuid?, llm_cost_usd?(str), search_cost_cents:int, job?}`. Order status ∈ pending|in_progress|delivered|failed|refunded; `pack_id` null until delivered. Errors are `{detail:"..."}`.

**iOS insertion points** (`apps/ios-app/Hangs/Hangs`, Swift 6 / Swift Testing / MVVM+service; NEVER `@Observable` — always `@MainActor final class : ObservableObject` + `@Published`, protocol-injected service with default+test inits):
- New files: `Services/PackOrderService.swift` (actor mirroring `NetworkService.swift:39-63`; own `baseURL` from a new `Config.packApiBaseURL`, inject `AuthServiceProtocol` for the bearer) + `Services/Mocks/MockPackOrderService.swift`; `Models/PackOrder.swift` (Codable, snake_case `CodingKeys` per `Session.swift:23-34`); `ViewModels/OrderPackViewModel.swift` (state enum per `StoreManager.swift:45-56`); `Views/OrderPackView.swift` / `OrderProgressView.swift` / `MyPacksView.swift`; `HangsTests/OrderPackViewModelTests.swift` (mirror `OnboardingViewModelTests.swift`).
- `Config.swift:14-19` + `Info.plist` + `Local.xcconfig`/`Prod.xcconfig` (after line 14): add `packApiBaseURL` / key `PACK_API_BASE_URL` = `http://localhost:8003` / `https://quiz-pack-api.fly.dev`.
- Admin key: mirror `KeychainTokenStore` (`AuthService.swift:708-762`) with a distinct account `"admin_key"`. Entry points visible only when a key is stored (`@State hasAdminKey`, loaded like `SettingsView.swift:44,106-109`).
- `SettingsView.swift:76` (between subscription/about groups), gated `if hasAdminKey`: admin-key field + `NavigationLink`s to OrderPackView + MyPacksView. **Entry OUTSIDE PaywallView** (concept-collision guard).
- Play the pack: `NetworkService.swift:15` (protocol) + `:123-153` (impl) add `packId: String?` → conditional `body["pack_id"]`; `QuizViewModel.swift:463-467` + `:511-518` add `packId` to `startNewQuiz` → `createSession`. `startQuiz` unchanged. MyPacksView "Start quiz" → `startNewQuiz(packId:)`.
- `AppState.swift:15-22` + both inits (`:59-64`, `:150-158`): add `packOrderService` (construct with `authService`).

**Auth model:** admin key in Keychain (no key in binary → works in TestFlight; visible entry only when stored). Bearer = `AuthService.accessToken` (same JWT is valid on quiz-pack-api — it shares `AUTH_JWT_SECRET`; subject matches). Send bearer on POST (linkage) + every GET; admin key on POST + GET-by-id.

**Fallback (founder call):** if the order→progress→delivered→play e2e doesn't pass cleanly, **hide the entry button, fail loud in the report, ship the rest** — do NOT block P4/P7.

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
