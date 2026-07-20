# Issue 113: Decompose the QuizViewModel god object

**Triage:** refactor · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 2. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 2 + dimensions 1, 3, 6, 7. Link, don't restate.

## Why (stub — Phase 2 expands)

QuizViewModel is 3,017 lines across 6 files (main 1519, +Recording 697, +Audio 305, +Timers 219, +CommandListener 203, +ScenePhase 74) owning state and business logic for 8+ screens plus paywall, quota, audio devices, voice commands, and timers. The `+Extension` split is file-partitioning, not decomposition — state is deliberately non-private so sibling files can reach in. ~36 @Published + ~17 non-observable mutable vars express ~10 independent axes as ~50 free variables; recording/confirmation clusters are de-facto sub-states reset by hand at 8+ sites (`resetState` misses `pendingSkipWindow` and `activeErrorModel`).

Review's concrete split: **RecordingCoordinator / VoiceCommandCoordinator / QuizTimersController / EntitlementReconciler** (reconcileEntitlements at `QuizViewModel.swift:806/827/863`) composed by a thin state-machine façade, one screen at a time; fold phase-scoped @Published clusters into QuizState associated values / per-phase sub-structs so leaving a phase drops its state atomically.

**Sequencing note:** run after #110 — quiz state-machine enforcement, #112 — error-path dedup, and #115 — iOS 26 target raise (deletes ~15 nil-branches in these very files), so the decomposition moves less code.

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
