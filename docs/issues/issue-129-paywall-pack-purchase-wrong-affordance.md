# Issue 129: Paywall: buying the pack shows the loading state on the Subscribe button and keeps the plan selected

**Triage:** bug · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test. Root cause CONFIRMED by direct code read (every cited line verified); the *fix* is half state-plumbing, half UI design and is gated on a Pencil design pass + founder sign-off. Needs `/prepare-issue` before an agent run. **2026-07-28: design gate PASSED — founder picked Variant C "The Button Narrates" (resolves both founder decisions below); see [ui-variants-2026-07-28-decisions.md](../design/ui-variants-2026-07-28-decisions.md). Next: Pencil sync, then code.**
**Created:** 2026-07-28

## Symptom

Founder, TestFlight, 2026-07-28, two screenshots. Tapping the "100 Question Pack" row on the paywall opens the **correct** StoreKit sheet ("100 Question Pack, 49,00 Kč, One-time charge") — the purchase itself routes to the right product. But on the paywall behind the sheet:

1. A spinner runs on the pack row (correct) **and simultaneously** on the big pink "Subscribe — 699,00 Kč / year" CTA, which is also frozen (non-tappable).
2. The Annual plan card stays visibly selected, pink check and all, throughout a purchase that has nothing to do with a subscription.

Founder: *"When buying a pack, the Subscribe button shows a loading state. That's weird. And at the same time the subscription is selected even though I'm buying the pack."*

No money/entitlement defect is reported or suspected — the purchase completes against the right product. This is purely a wrong-affordance / misleading-state bug on the paywall.

## Root cause

**CONFIRMED** — both halves read directly in the current source.

**(1) CTA spinner — one global loading flag, not per-product.**
`StoreManager.isLoading` is a single app-wide `@Published` bool (`apps/ios-app/Hangs/Hangs/Services/StoreManager.swift:74`), set true at `:133` and false at `:188` around **every** `purchase(productID:)` call, pack or subscription alike. The Subscribe CTA passes exactly that flag into the button (`PaywallView.swift:437` annual branch, `:446` monthly branch), and `HangsPrimaryButton.isLoading` both spins **and** disables (`Components/Hangs/HangsButton.swift:97` `.disabled(isLoading)`; the doc comment at `:19-24` explicitly contrasts it with `showsSpinner`, which spins without disabling). That is the frozen spinning pink CTA in the screenshot.
The correct pattern already exists one row above: the pack row checks per-product state, `storeManager.purchaseState == .purchasing(productID: pack.id)` (`PaywallView.swift:397`). `PurchaseState` carries the productID (`StoreManager.swift:45-58`, set at `:135`); `isLoading` does not. The per-product pattern was simply never applied to the CTA.

**(2) Plan stays selected — selection has no notion of "something else is being bought".**
`selectedPlan` is local View `@State` (`PaywallView.swift:31`), defaulted to `.annual` (`:37,:42`), mutated **only** by plan-card taps (`:286`, `:298`). `packCard`'s action is just `Task { await storeManager.purchase(productID: pack.id) }` (`:384`) and never reads or writes it. `effectivePlan` (`:261`) only adds an annual↔monthly fallback for partial offerings. So the pink check means "what the CTA would buy", and nothing in the model expresses "a non-plan product is currently in flight". Per the header comment (`:6-8`) and the [#94 — paywall z8TS6 sync](issue-94-paywall-z8ts6-sync.md) spec, this cross-product state was never specified — a design gap, not a coding slip.

**Verified beyond the original investigation:**
- The inverse also happens: the pack row is `.disabled(storeManager.isLoading)` (`PaywallView.swift:422`), so a *subscription* purchase greys the pack row. Whatever affordance is chosen must be decided in both directions.
- `restorePurchases()` sets the same flag (`StoreManager.swift:211`/`:236`), so tapping "Restore purchases" **also** spins and freezes the Subscribe CTA and disables the pack row today. Same confirmed defect class, not a hypothetical.
- The no-offerings branch passes `isLoading: true` unconditionally (`PaywallView.swift:456`) — that is the offerings-load placeholder and is out of scope.

## Scope of a fix

**Gate (blocking): proper design pass before any implementation.** The paywall's in-flight states must be designed and signed off by the founder **before** code is written. Implementation without sign-off is out of bounds.

**Process — founder decision 2026-07-28, applies to every UI issue: HTML variants first, Pencil second, code third.** The agent generates several *HTML* variants of the paywall in-flight states, the founder reviews and picks one; only the chosen variant is drawn into `design/quiz-agent.pen` (frame z8TS6), and only then implemented. Never Pencil-first, never code-first. `⌘S` / approval stays the founder's step.

Questions the design session must answer (visual hierarchy, not code):
- What does the paywall look like while a **pack** purchase is in flight: does the Subscribe CTA dim, stay full-strength, or gain a "not now" treatment? Is there exactly one visible busy indicator on screen, or two?
- What does it look like while a **subscription** purchase is in flight — does the pack row keep its greyed-out treatment (`:422`), and is that legible as "temporarily unavailable" rather than "broken"?
- Does the pink selection check stay on Annual/Monthly during a pack buy, move, or gain a third "nothing selected / pack in progress" state? What replaces the pink check if it goes away, so the picker does not read as empty/broken?
- Same question for "Restore purchases", which today freezes the CTA identically.
- Does the pack row need to read as a **peer** of the plan cards or as a clearly secondary escape hatch? The screenshot shows the CTA visually dominating an action the user did not take.

**(A) State plumbing — after sign-off.**
- Give the CTA per-product in-flight state: gate its spinner/disabled state on `purchaseState == .purchasing(productID: selectedProduct.id)` (mirroring `:397`) instead of the blanket `storeManager.isLoading` at `:437`/`:446`.
- Decide the fate of `StoreManager.isLoading` as a paywall input: either scope every paywall call site per-product, or keep it strictly as "any store operation in flight" and let the design decide what that should render. Audit both remaining consumers — pack row `:422` and restore `StoreManager.swift:211`.
- Whatever "no plan is being acted on" the design lands on must live in state the View can express — today `selectedPlan` cannot represent it.
- Confirm reentrancy: `.disabled` on both controls currently prevents a second purchase starting mid-flight; if the design loosens either disable, `StoreManager.purchase(productID:)` must be checked for safe overlapping calls (it has no in-flight guard of its own).

**(B) Regression cover.**
- A paywall-level test asserting that a pack purchase in flight does **not** put the Subscribe CTA into its loading/disabled state — the assertion that fails on today's code.

## Founder decisions needed

> **2026-07-28:** both resolved by the HTML variant pick — **Variant C "The Button Narrates"**: the CTA morphs into the status narrator for whichever product is in flight (not interactive mid-flight, never dead-looking, no row spinners); the pink selection check is kept but demoted. See `docs/design/ui-variants-2026-07-28-decisions.md`.

1. **While a pack purchase is in flight, should the Subscribe CTA stay fully interactive (no spinner, tappable), or be disabled-but-not-spinning?** Tradeoff: fully interactive is the most honest reading of "you are not subscribing right now", but permits a second purchase sheet on top of the first; disabled-but-not-spinning prevents that at the cost of a briefly dead-looking primary CTA. (Same call applies to "Restore purchases".)
2. **Should the Annual/Monthly card visually deselect during a pack purchase?** Tradeoff: keeping the pink check is defensible ("this is what you'd buy next") and the founder still read it as wrong; deselecting removes the contradiction but leaves the picker with no selection, which needs its own visual treatment and a rule for what happens after the pack purchase resolves.
3. Both are UI-design calls — answer them **in the design session**, against a drafted frame, not in prose.

## Related

- [#94 — paywall z8TS6 sync](issue-94-paywall-z8ts6-sync.md) — defined the current plan-picker + pack-card layout; the screenshot is that design working as laid out. Its spec never covered cross-product loading/selection semantics, so this is a genuine gap, not a duplicate. Any new frame here supersedes z8TS6's in-flight states.
- [#93 — subscription IAP + packs](issue-93-subscription-iap-packs.md) — shipped the purchase logic and RC offerings this paywall drives. **Out of scope here:** purchase correctness, entitlement/credit grants, RC product mapping. All of that is behaving correctly per the field report.
- [#114 — MVVM conformance for Account/Paywall](issue-114-mvvm-conformance-account-paywall.md) — pure refactor; its `PaywallViewModel` exposes `isLoading`/`selectedPlan` as passthroughs with "no purchase state copied into a `@Published`" (`:75`, `:143`), so it carries this bug forward unchanged. It is neither a fix nor a blocker; if #114 lands first, fold this fix into the ViewModel instead of the View.
- **Out of scope:** the offerings-load placeholder spinner (`PaywallView.swift:456`) and the offline "CAN'T REACH THE STORE" (PouwN) variant.
