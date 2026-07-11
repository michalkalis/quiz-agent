# Issue #94 — Paywall: sync PaywallView to z8TS6 design (plan picker)

**Triage:** enhancement · done 2026-07-11 (see Resolution below)

**Created:** 2026-07-11 · **Source:** founder report "implementacia neni v syncu s pencil designom" → diagnosis workflow 2026-07-11

## Problem

The two newest design commits (762d232, 7bcb805, both #93 — subscription IAP) added frame **z8TS6 "NEW_Screen/Paywall-Subscription"** to `design/quiz-agent.pen`, but `PaywallView.swift` still implements the older u2ySy "OUT OF QUESTIONS" layout with annual/pack bolted on as small ghost buttons. Quiz/question/home screens were audited the same day and are **in sync** — the paywall is the only real drift.

The z8TS6 design:
- Plan picker: **Annual card pre-selected** (€29.99/yr, pink stroke + check radio) + Monthly card (€4.99/mo)
- Pack card: "100 Question Pack — one-time purchase · never expires" + price pill (€1.99), styled as a card (not ghost link)
- Single primary CTA interpolating the selected plan: "Subscribe — €29.99 / year"
- Auto-renew legal line: "Auto-renews until cancelled. Cancel anytime in Settings." — **App Store review requirement**, this raises the issue above cosmetic
- Close X in the brand row

## Scope

1. Rebuild `paywallBody` in `apps/ios-app/Hangs/Hangs/Views/PaywallView.swift` to z8TS6: selected-plan state (`annual|monthly`), two tappable plan cards, pack card, single dynamic CTA using the selected plan's RevenueCat `displayPrice`, legal footnote.
2. Keep: Restore link, "Maybe tomorrow" dismiss, the offline `PouwN` variant untouched, `limitError` optionality (proactive vs 429 presentation — entry points shipped 2026-07-11 are layout-independent and must keep working).
3. Brand row: use the existing shared brand component — after #92 Session 1 it already renders "trubbo." (z8TS6's "trubbo." is the approved rename, NOT a drift).
4. Design-side cleanup while in Pencil: archive/remove stale frame `nidTF` (Quiz-EndConfirm — superseded by the #81 native alert). **[HUMAN]** founder ⌘S-saves the .pen after MCP edits (known from #77 task 77.12).
5. Tests: extend paywall tests (plan selection → CTA label, legal line present, limitError nil vs 429 copy). Targeted suites only.
6. TestFlight after commit.

## Locked decisions / answered

- "trubbo." in z8TS6 = approved #92 rename, implement with current brand component.
- Entry points (Home quota card + Settings row) shipped separately 2026-07-11; do not rework them here.

## Open product questions (ask founder in-session)

1. RC `displayPrice` is locale-formatted and may differ from the €-hardcoded design prices — accept localized prices? (Recommended: yes, RC price is the truth.)
2. Ship a third paywall touchpoint — CompletionView soft upsell when ≤5 free questions remain (highest-intent moment)?

## Resolution (2026-07-11)

- `paywallBody` rebuilt to z8TS6: `PaywallPlan` selection state (annual pre-selected), Annual/Monthly tappable cards (pink stroke + check radio vs grey + hollow), "SAVE 50%" badge, "or top up without subscribing" + pack card (purple price pill, tap = direct purchase), single CTA "Subscribe — {RC displayPrice} / year|month", auto-renew legal line, close X in brand row. Headline unified to "GO UNLIMITED" (z8TS6); quota-hit vs proactive still differ via subtitle + reset pill (restyled to dark mono capsule). Feature card ("unlimited" checklist) dropped — not in z8TS6. Offline PouwN variant untouched.
- Open Q1 answered: **localized RC prices accepted** (founder, in-session). Q2 answered: **yes** — CompletionView soft upsell shipped (free user, ≤5 remaining → "Running low…" card + Go Unlimited → presentPaywall; `refreshUsage()` on completion appear; `MockNetworkService.stubbedUsage` added for tests).
- Pencil: stale frame nidTF (Quiz-EndConfirm) deleted via MCP; **[HUMAN]** founder ⌘S-save pending.
- Tests: PaywallViewInspectorTests rewritten for z8TS6 (plan cards, CTA suffix per selection incl. `initialPlan` injection + partial-offerings fallback, legal line, offline exclusions); CompletionView upsell suite added; 29/29 targeted green; 2 paywall `.dump` snapshot baselines re-recorded (intentional redesign).
- Note: new UI strings enter `Localizable.xcstrings` on next Xcode IDE build (CLI doesn't write back — #56 known caveat).

## References

- Diagnosis: workflow run wf_40420ee0-a61, 2026-07-11 (design agent read z8TS6 via pencil MCP: nodes planAnnual/planMonthly/packCard/ctaBtn/legal)
- `docs/issues/issue-93-subscription-iap-packs.md` — purchase logic (RC offerings, entitlement sync) already shipped; this issue is layout-only
- `docs/issues/issue-92-rename-trubbo.md` — brand row status
