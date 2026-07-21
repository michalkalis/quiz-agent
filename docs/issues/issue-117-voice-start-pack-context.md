# Issue 117: Voice "start" plays the visible delivered pack (pack-context command routing)

**Triage:** feature · triaged
**Status:** Filed 2026-07-20 from [#111 — navigation as owned state](issue-111-navigation-owned-state.md) § Execution residual **R1**; founder confirmed the follow-up interactively 2026-07-20. Needs `/prepare-issue` before an agent run.
**Created:** 2026-07-20

## Why

Saying "start" while looking at a delivered pack (OrderProgress with the "Start quiz" CTA, or a MyPacks row) starts a **generic** quiz: `routeCommand`'s `(.home, .start)` calls `startNewQuiz()` with no packId (`QuizViewModel+CommandListener.swift:169`), while the on-screen CTA calls `startNewQuiz(packId:)`. #111 fixed the covering-screen half (the pushed stack now tears down on any quiz start); the pack-context half remains — a hands-free driver must tap the CTA to get the pack they ordered, contradicting the voice-first product rule.

## Sketch (input for /prepare-issue, not binding)

- A "visible pack context" seam consumed by `routeCommand`'s `.start` when `quizState == .idle` — e.g. derived from the #111 `NavigationModel` route/`orderProgressPresented`, or a `lastDeliveredPackId` the OrderProgress/MyPacks screens set.
- Distinguishable mock fixtures per packId so the RS can tell pack vs generic start — #111's `testRSPackNavStart` pass 2 cannot (`MockNetworkService` returns the same quiz fixture for any packId), which is exactly how the gap stayed invisible.
- Coordinate with [#113 — QuizViewModel decomposition](issue-113-quizviewmodel-decomposition.md) (`routeCommand` moves there); cheap to fold in if #113 runs first.
