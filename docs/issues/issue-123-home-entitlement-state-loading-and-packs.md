# Issue 123: Home: free-question count missing at launch, no loading placeholder, no pack/subscription state

**Triage:** bug · Track A done — Track B design-gated
**Status:** Filed 2026-07-28 from the founder's TestFlight field test; both halves CONFIRMED by direct code read. **Track A landed same day (`23b9e843`, worktree agent run):** `HomeView.freePlanCard` gained a `.loading` branch (spinner + "Loading your plan…", same single-row `HangsCard` shape as the failed placeholder so the slot never jumps), and `SettingsView.subscriptionPlanDisplay` returns "Loading…" instead of the wrong literal "Free" while `/usage` is in flight. 9 targeted tests green (`HomeFreePlanCardTests` 8/8 incl. the assertion that failed pre-fix, `SettingsSubscriptionPlanTests` 1/1); sim visual check done in light + dark against a deliberately stalled `/usage`. Remaining: **Track B** (pack credits + subscription tier on Home) — design-gated, HTML variants → founder pick → Pencil → code. **2026-07-28: founder picked Variant A "One adaptive balance card" (see [ui-variants-2026-07-28-decisions.md](../design/ui-variants-2026-07-28-decisions.md)); next = Pencil sync, then code.**
**Created:** 2026-07-28

## Symptom

Founder, TestFlight, 2026-07-28:

> "I still don't like that the state of available free questions is not shown right after launch. There should at least be a loading placeholder so the user knows the count is loading. And info about purchased packs and subscriptions is missing there too?"

Two things in the same Home card slot:

- **A.** Right after launch the plan card is *absent* — not empty-looking, not spinning, simply not rendered — until `/usage` returns. The user cannot tell whether the count is loading, is zero, or has broken.
- **B.** Even once loaded, Home shows only "N of M free questions left" (free) or "Unlimited questions" (premium). Pack credits and subscription status never appear there, although Settings already shows both.

## Root cause

**CONFIRMED — (A) missing `.loading` branch.**
`HomeView.freePlanCard` (`apps/ios-app/Hangs/Hangs/Views/HomeView.swift:111-131`) has exactly two branches: `usageInfo != nil`, and `usageLoadState == .failed`. There is no branch for `.loading`, so SwiftUI renders `EmptyView` for the whole in-flight window. The enum's own doc comment states the behaviour outright — "The card shows nothing" (`ViewModels/EntitlementReconciler.swift:26-29`). `usageLoadState` starts at `.loading` (`EntitlementReconciler.swift:45`), and `usageInfo` is in-memory only (no disk cache anywhere in the app — grep shows the only writers are `EntitlementReconciler` and the `QuizViewModel` façade), so **every cold launch reproduces the blank window**, network speed only changes its length.

The 2026-07-23 cold-start fix (`bd6ff6e`) added the `.failed` retry placeholder (`HomeView.swift:133-162`) because the symptom then was the card *vanishing after a failure*. It deliberately left the loading window as designed. So this report is the untouched twin of that fix, not a regression of it.

Worst-case blank duration: `performUsageRefresh` is 3 attempts with 0.2/0.4s backoff (`EntitlementReconciler.swift:154-171`) and `getUsage` uses a **10s** request timeout (`Services/NetworkService.swift:537`) — roughly 30s on a fully stuck Fly cold start, then the `.failed` placeholder finally appears.

**CONFIRMED — (B) Home's card predates the entitlement states it should show.**
`UsageInfo` already carries `subscriptionStatus` and `creditBalance` (`Models/UsageInfo.swift:18-21`), delivered by the very call that fills the Home card. `SettingsView.subscriptionPlanDisplay` already renders them ("Free · N credits", `Views/SettingsView.swift:585-591`). But `HomeView.freePlanCardBody` branches on `usage.isPremium` alone (`HomeView.swift:164-199`) and never reads either field. Reason: [#87 — Home: free-plan question counter + reset countdown](issue-87-home-freeplan-counter.md) locked the paid state as a plain "Unlimited questions" row on 2026-07-07, three days before [#93 — subscription IAP + question packs](issue-93-subscription-iap-packs.md) shipped packs and tiers to prod. #87's own founder-direction section explicitly listed "pack balance?" as an open option for that slot; the 2026-07-07 answer settled it before packs existed, and the slot was never revisited.

Consequence today: a free user holding pack credits sees only "N of 100 free questions left" on Home, with the credits they paid for invisible.

## Scope of a fix

**Track A — loading placeholder (no design gate, code-only).**
- Give `HomeView.freePlanCard` a `.loading` branch so the slot is never silently blank from first appearance through resolution (loaded *or* failed). Reuses the existing `UsageLoadState`; no new state needed.
- Keep the shape/height stable across loading → loaded → failed so the Home layout does not jump.
- Same class of gap in Settings, in scope if cheap: `subscriptionPlanDisplay` returns the literal "Free" before `usageInfo` loads (`SettingsView.swift:582-584`) — an unlimited subscriber is briefly told they are on Free. Should read as loading, not as a wrong answer.

**Track B — pack + subscription state on Home. DESIGN GATE, mandatory.**
- **No implementation until a proper design pass exists and the founder has signed off.**
- **Process — founder decision 2026-07-28, applies to every UI issue: HTML variants first, Pencil second, code third.** The agent generates several *HTML* variants of the revised Home plan-card states, the founder reviews and picks one; only the chosen variant goes into Pencil (`design/quiz-agent.pen`, the frame 86.8 slot from #87), and only then into code. Never Pencil-first, never code-first. `⌘S` save stays the founder's step.
- The design session must answer, explicitly:
  - What states the slot must express: free-with-quota · free-with-pack-credits · free-with-both · subscribed-active · subscribed-grace · subscribed-expired · loading · failed. Which of these get their own visual, which collapse.
  - Visual hierarchy when a user has both monthly free questions and pack credits — which number is primary, and what the progress track then represents (it currently maps to the free quota only).
  - Whether the card stays one card or splits (plan row + credits row), given the whole card is currently a single tap target for the paywall (`HomeView.swift:117-123`) — two meanings in one tappable surface needs a decided target.
  - What the paywall/upgrade affordance becomes for a user who already subscribes or already holds credits (today "Upgrade" + chevron is free-only).
  - Grace/expired treatment: does Home warn about a lapsing subscription, or is that Settings-only.
  - Loading placeholder treatment for the new states, so Track A's design is not invalidated by Track B.
- Only after sign-off: wire `creditBalance` / `subscriptionStatus` into `freePlanCardBody`. Data is already fetched — this is presentation, not plumbing.

**Verification:** targeted HangsTests for the loading/failed/loaded branches plus the new entitlement states, and a sim visual check (light + dark) per the UI-verification rule.

## Founder decisions needed

> **2026-07-28:** the Variant A pick implicitly resolves decision 3 — a free user's pack credits DO show on Home, folded into the card's combined free+credits total (`docs/design/ui-variants-2026-07-28-decisions.md`).

1. **Loading placeholder treatment (Track A):** skeleton/shimmer bar · plain spinner in the card · static "Loading your plan…" text. Tradeoff — skeleton reads as "unknown duration" and best matches a variable Fly cold start, but is the most new styling; a spinner is cheapest and matches existing `HangsPrimaryButton` behaviour; static text is loudest for a driver's glance but least polished. Recommend deciding this one in-session so Track A can ship without waiting on Track B's design pass.
2. **Does Track A ship independently of Track B?** Splitting means the blank-at-launch complaint is fixed now and the pack/subscription redesign follows the design gate. Bundling means one visual change but the founder's most-repeated complaint waits on a design session.
3. **Should a free (non-subscribed) user's pack credits show on Home at all,** or is that combination deferred until the packs product story is settled? #87's original design only ever considered `isPremium` as a binary.
4. **New issue vs. reopening #87's paid-state task:** this file assumes a new issue; say if the Track B half should instead be folded back into [#87 — Home: free-plan question counter + reset countdown](issue-87-home-freeplan-counter.md).

## Related

- [#87 — Home: free-plan question counter + reset countdown](issue-87-home-freeplan-counter.md) — shipped the card slot; its 2026-07-07 paid-state decision is Track B's root cause.
- [#93 — subscription IAP + question packs + free-tier resize](issue-93-subscription-iap-packs.md) — source of `creditBalance` / `subscriptionStatus`, shipped after #87's design was locked.
- 2026-07-23 cold-start triage (no issue number, commit `bd6ff6e`, memory `project_regressions_2026_07_23`) — fixed the `.failed` half of this same card; this issue is the `.loading` half.

**Out of scope:** changing `/usage` itself, its retry/backoff policy, or the Fly cold-start latency behind it (the payload already carries everything needed); the paywall sheet's own content; Settings' subscription row beyond the loading-state correction noted in Track A.

**Open question for prep:** no telemetry was pulled on real observed `/usage` durations on cold Fly starts. `SentryLog` breadcrumbs from `EntitlementReconciler` would size how long the placeholder actually persists and whether an indeterminate skeleton or a determinate indicator is the honest choice — worth doing during `/prepare-issue`, not a blocker for filing.
