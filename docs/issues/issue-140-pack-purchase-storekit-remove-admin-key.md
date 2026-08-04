# Issue 140: Custom-pack purchase must run on real StoreKit payment — retire the admin-key path for users

**Triage:** enhancement · agent-side DONE 2026-08-04 · awaiting founder leg (class c — payments; ASC product + price, sandbox e2e)
**Reversibility:** c
**Status:** Founder 2026-08-04: "ten admin kľúč už snáď netreba… nech to poriadne funguje aj pre bežných užívateľov" — test via sandbox purchases in the TF build. This is #95's deferred Session 4 (payments), now due.
**Created:** 2026-08-04

## Current state (confirmed 2026-08-04)

- Backend `POST /v1/orders` (`orders.py:229-407`) already accepts **either** `X-StoreKit-JWS` (fully verified Apple receipt incl. revocation) **or** `X-Admin-Key` (synthetic `admin-…` transaction, the deliberate #95 founder-phase door, `deps.py:191-213`). The JWS path is enforced when used — no verification gap; the admin door is just still the only one the app walks through.
- iOS always attaches the Keychain admin key (`PackOrderService.swift:158-159`, `AdminKeyStore.swift`), and the whole custom-packs Settings group is **admin-key-gated** (`SettingsView.swift:770-820`) — regular users can't even see the feature.
- Founder's 2026-08-03 order was admin-path → **no charge occurred** (confirmed in prod DB), consistent with the founder's "myslím, že som ani neplatil".

## Scope

1. iOS: purchase the pack product via StoreKit (product + entitlement plumbing exist from #93 — packs shipped there; paywall already buys packs) and send the JWS to order creation; stop attaching the admin key for user flows.
2. iOS: ungate the custom-packs entry from the admin key (coordinate placement with #138 modal + #141 Home entry).
3. Keep the admin door for internal testing only (backend flag stays; iOS attaches it only in Debug/internal builds — decide exact mechanism at impl).
4. Price/product review with founder: this is a premium-priced product (founder: "premiová vcelku, takže drahšia") — confirm the ASC product + price point before ungating.
5. Founder leg: sandbox purchase e2e in a TF build (order → charge → generation → play). Watch #101's env note — sandbox vs prod entitlement separation.

## Acceptance

- [x] User flow sends `X-StoreKit-JWS`, never `X-Admin-Key` (unit test on `PackOrderService` request construction in user mode) — `PackOrderServiceTests` section 5; the user-mode test injects an available admin key and proves it does NOT ride along.
- [x] Custom-packs entry visible without an admin key (unit/snapshot) — `SettingsPacksEntryTests` (ViewInspector, Keychain cleared).
- [x] Admin path unreachable in Release user builds — build-config evidence: `#if DEBUG` wraps the `X-Admin-Key` attachment (`PackOrderService.makeRequest`), the Settings admin-key field (`SettingsView.packsGroup`), and the VM's skip-payment branch (`OrderPackViewModel.resolvePaymentProof`).
- [ ] `[HUMAN]` Founder sandbox purchase e2e passes on device (charge shown, pack delivered, playable).
- [x] Backend untouched (JWS path shipped in #95/#133 already enforced); no model moves, `/verify-api` not needed.

## Implementation notes (2026-08-04, agent run)

- Purchase is **raw StoreKit 2** (`StoreKitPackPurchaseService`), NOT RevenueCat: RC keeps `jwsRepresentation` internal, and quiz-pack-api authorises orders from the raw Apple JWS. Subscriptions + #93 credit pack stay on RC.
- Product id = `pack_30` (must match the server's `_PRODUCT_TIERS` key AND the ASC product id — the server cross-checks the JWS payload against the body). Founder creates the ASC consumable with EXACTLY this product id.
- Crash-safety: proof (JWS + tx id) persists in `PendingPackPurchaseStore` BEFORE `transaction.finish()`; an interrupted order retries from the pending proof (no double charge), cleared only after the backend accepts the order. VM tests pin purchase-once/reuse/clear.
- Prod quiz-pack-api runs `STOREKIT_ENVIRONMENT=Sandbox` (verified on the machine) — TestFlight sandbox purchases will verify as-is.
