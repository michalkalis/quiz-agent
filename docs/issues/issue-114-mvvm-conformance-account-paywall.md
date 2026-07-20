# Issue 114: MVVM conformance — AccountViewModel, PaywallViewModel, DI seams, auth Sentry logging

**Triage:** refactor · needs-triage
**Reversibility:** a (code-only; touches SIWA + purchase-orchestration surfaces → maker≠checker review leg mandatory; pipeline decides ready-for-agent vs ready-for-human per the class-b guard)
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 items 4, 8, 10. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 items 4, 8, 10 + dimensions 1, 2, 9. Link, don't restate.

## Why (stub — Phase 2 expands)

One target-architecture rule enforced across the three worst offenders — *Views hold presentation @State only; no service calls, no Keychain reads, no purchase orchestration in a View*:

1. **AccountViewModel** (Top 10 item 4) — SettingsView embeds the full Apple sign-in/sign-out/delete-account/export-data flow view-side (`SettingsView.swift:114/460`); ContextualSignInSheet duplicates it and the copies have diverged in error handling (`ContextualSignInSheet.swift:201`). Add `isSignedIn` to AuthServiceProtocol; delete all five ad hoc `KeychainTokenStore()` reads (+ `ContentView.swift:196`); protocol seam for AdminKeyStore.
2. **PaywallViewModel** (Top 10 item 8) — PaywallView binds directly to concrete StoreManager; purchase triggering, success auto-dismiss timing, and plan-fallback selection live in the View on the revenue-critical screen (`PaywallView.swift:27`).
3. **AuthService → SentryLog** (Top 10 item 10) — 823-line AuthService has zero Sentry integration; critical auth events reach only local os.Logger, invisible to production monitoring (`AuthService.swift:350`). Route warning/error-level events through SentryLog so TestFlight auth incidents are queryable via /check-crashes.

Adjacent (same rule, small): MyPacksView calls PackOrderService directly while sibling pack screens use OrderPackViewModel (`MyPacksView.swift:14`).

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ⬜ pending | — |
| 2 · Plan              | ⬜ pending | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 11:19 · **Next:** Phase 1 · **Gate attempts:** P3 0/3 · P5 0/3
