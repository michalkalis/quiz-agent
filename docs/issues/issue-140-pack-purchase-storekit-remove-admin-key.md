# Issue 140: Custom-pack purchase must run on real StoreKit payment — retire the admin-key path for users

**Triage:** enhancement · ready-for-human (class c — payments; agent implements attended, founder does the sandbox leg)
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

- [ ] User flow sends `X-StoreKit-JWS`, never `X-Admin-Key` (unit test on `PackOrderService` request construction in user mode).
- [ ] Custom-packs entry visible without an admin key (unit/snapshot).
- [ ] Admin path unreachable in Release user builds (test or build-config grep evidence).
- [ ] `[HUMAN]` Founder sandbox purchase e2e passes on device (charge shown, pack delivered, playable).
- [ ] Backend untouched or changes covered by pytest; `/verify-api` clean if models move.
