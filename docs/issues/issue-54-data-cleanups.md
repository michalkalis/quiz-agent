# Plan 54.11 / 54.13 / 54.16 + hygiene 54.19–54.21 — data + component cleanups (batchable)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.11, §54.13, §54.16, §54.19–§54.21) · **Priority:** P2
**Status:** ready · These are the leftover cleanups not done in the 2026-06-12 session (the
trivial view-only ones — 54.9/54.10/54.12/54.14-lineSpacing — already landed in commit `40b9ff0`).
Each here needs a small bit more than a one-line view edit.

---

## 54.11 — ResultView "streak was X" uses all-time best, not the prior streak
`ResultView.swift:338` (`previousStreakForIncorrect`) uses `quizStats.bestStreak` as the "was" value
on an incorrect answer; the code comment admits it's a "proxy". Best-ever ≠ the streak just before
this answer.
**Why it needs more than a view edit:** the value to show (the streak *immediately before* the reset)
isn't currently retained — by the time ResultView renders, `currentStreak` is already 0.
**Plan:** add a VM field that captures the streak *before* it's reset on an incorrect answer (e.g.
`streakBeforeLastAnswer`, set in the same place `currentStreak` is zeroed), and read it in ResultView.
**Test:** VM test — after an incorrect answer following a streak of N, the field reads N.

## 54.13 — fractional scores truncated by `Int(score)`
`QuizCompleteSummary.swift:35` (`correct = Int(score)`) and `CompletionView.swift:56`
(`Int(summary.finalScore)`) floor a `Double`. Partial scoring **is** active (the `Evaluation` result
enum has `.partiallyCorrect` / `.partiallyIncorrect`, and `score = participant.score` comes from the
backend), so with partial credit the final score displays low and `incorrectCount = answered -
correct` becomes wrong (can exceed total).
**Display decision — RESOLVED 2026-06-12 (founder): show the fractional score as-is** ("3.5 reads
fine") — i.e. option (a): display the score with one decimal (drop the trailing `.0` for whole
numbers), and stop deriving counts from it. Concretely: `CompletionView` hero shows the real
`finalScore` (formatted, not `Int()`-floored); `QuizCompleteSummary` must not compute
`correct = Int(score)` — derive correct/incorrect counts from the actual per-answer evaluations
(or drop the count framing where only points are available), so `incorrectCount` can no longer
exceed total.
**Test:** `QuizCompleteSummaryTests` cases for a fractional score — display string "3.5", counts
consistent (correct + incorrect ≤ answered).

## 54.16 — MCQOptionPicker: tap/voice race + missing animation on voice match
`MCQOptionPicker.swift:48` — `submitAfterDelay` spawns a detached `Task` with **no handle**; if a
voice match (`externalSelectedKey`) lands concurrently with a tap, `onSelect` can fire twice (no
cancellation). Also the row animation keys on local `selectedKey` only (`:41`), so a voice-driven
selection snaps without animation.
**Plan:** hold the `submitAfterDelay` Task in `@State` and cancel it if a voice match arrives (or
guard `onSelect` to fire once); change the `.animation(value:)` key to `effectiveSelectedKey` so a
voice selection animates. **Test:** a VM/inspector test that a concurrent tap+voice-match yields a
single `onSelect`; verify the voice-match animation in-sim.

---

## Hygiene items (found 2026-06-12 second review pass — quick, no product decisions)

### 54.19 — `HangsMic.swift` is dead code
`Views/Components/Hangs/HangsMic.swift` — `HangsMicBlock`/`HangsMicMode` was built by #52 for the
big circular mic button, but the final 52.10 QuestionView uses an inline capsule Record button
instead. Zero production callers (only its own `#Preview`); ~130 lines incl. an animation loop and
`Color.white` that would pollute the 54.1 dark-mode audit. **Fix: delete the file.**

### 54.20 — stale `QuestionPage.statusPill` page-object member
`HangsUITests/Pages/QuestionPage.swift:28–30` references `question.statusPill`, an identifier the
#52 redesign removed from QuestionView. No test calls it today, but it's a silent trap for future
tests. `QuestionViewSnapshotTests.swift:17,89` comments also still mention it. **Fix: remove the
property + fix the comments.**

### 54.21 — negative `.lineSpacing` no-op sweep (same class as the fixed 54.14)
SwiftUI ignores negative line spacing (silent no-op; likely meant `tracking`/font tweak). 54.14
removed it from HangsQuestionCard, but three more remain: `ResultView.swift:83` (`-6`),
`AnswerConfirmationView.swift:147` (`-2`), `ScoreCard.swift:25` (`-4`). **Fix: remove all three**
(visual no-op today, so no snapshot churn expected — verify).

### Test-gap note (54.10 follow-up)
The landed 54.10 fix (`totalQuestions` fallback → `settings.numberOfQuestions`,
`ResultView.swift:300`) has **no verifying test** — add an inspector case: settings = 5 questions,
`currentSession == nil`, counter shows 5.

## Done criteria
- [ ] 54.11 VM field + test; 54.16 single-submit guard + animation; 54.13 per the resolved
      decision above (fractional display, counts from evaluations).
- [ ] 54.19 file deleted · 54.20 page object + comments cleaned · 54.21 three no-ops removed ·
      54.10 inspector test added.
- [ ] Update parent §54.11/§54.13/§54.16/§54.19–§54.21 status.
