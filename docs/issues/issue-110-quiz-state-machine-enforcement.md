# Issue 110: Quiz state-machine enforcement (driving-loop correctness bugs)

**Triage:** bug · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 1. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 1 + dimension 3 (state management). Link, don't restate.

## Why (stub — Phase 2 expands)

QuizState has a validated transition table but it is bypassed on real driving-loop paths. Four confirmed correctness bugs:

1. **Error-screen "Try Again" bypasses the state machine + no single-flight** — `startNewQuiz()` ignores the rejected `error→startingQuiz` transition and runs session creation while `quizState` stays `.error`; a double-tap fires two concurrent `createSession` calls that clobber `currentSession` (`QuizViewModel.swift:555`).
2. **Skip-undo expiry commits mid-recording** — the 2.5 s undo-window expiry rechecks only `pendingSkipWindow`, never `quizState`, so speaking/tapping during the window lets expiry commit `skipQuestion()` during `.recording` — leaving the streaming mic live into the result — or fire a concurrent skip against an in-flight answer (`QuizViewModel.swift:1069`).
3. **Stale minimized overlay on finish** — `.finished` never clears `isMinimized` and nothing cancels auto-advance on minimize → CompletionView with a stale MinimizedQuizView floating on top (`QuizViewModel.swift:1379`).
4. **MCQ selection has two sources of truth** — view-local `selectedKey` vs VM `mcqVoiceMatchedKey` (local-wins): tap A then voice-match B submits B while the UI highlights A (`MCQOptionPicker.swift:44`).

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
