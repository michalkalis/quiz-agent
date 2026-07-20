# Issue 111: Navigation as owned state (pack-nav broadcast + voice-"start" bypass)

**Triage:** bug · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 3. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 3 + dimension 4 (navigation). Link, don't restate.

## Why (stub — Phase 2 expands)

Two incompatible navigation models are bridged by a hidden NotificationCenter broadcast, and one real driving-loop bug already ships through the gap:

1. **Voice "start" over a pushed stack** — the "start" voice command calls `startNewQuiz()` directly and never triggers the `.packQuizStarted` stack teardown, so saying "start" while Settings/OrderPack/MyPacks is pushed leaves that screen covering the freshly-started QuestionView (`QuizViewModel+CommandListener.swift:169`).
2. **Broadcast + identity-reset navigation** — ContentView bridges the quizState-keyed root swap and a real NavigationStack push chain by force-recreating stack identity (`navStackID = UUID()` + `.id()`) on a NotificationCenter broadcast fired from a single call site (SettingsView.playPack); any listener/ordering change breaks the #95 — custom quiz packs flow silently (`ContentView.swift:186`).

Target-architecture rule: navigation is observable state (route enum / NavigationPath) owned by one object; no NotificationCenter broadcasts, no `.id()` identity resets.

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
