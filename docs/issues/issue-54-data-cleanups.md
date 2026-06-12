# Plan 54.11 / 54.13 / 54.16 — Result/Completion data + component cleanups (batchable)

**Parent:** `issue-54-design-refresh-regressions.md` (§54.11, §54.13, §54.16) · **Priority:** P2
**Status:** ready · These are the leftover cleanups not done in the 2026-06-12 session (the
trivial view-only ones — 54.9/54.10/54.12/54.14-lineSpacing — already landed in commit `40b9ff0`).
Each here needs a small bit more than a one-line view edit.

---

## 54.11 — ResultView "streak was X" uses all-time best, not the prior streak
`ResultView.swift:347` (`previousStreakForIncorrect`) uses `quizStats.bestStreak` as the "was" value
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
**Blocked on a display decision (founder):** what does a 3.5-point score mean as a *count*? Options:
(a) show the score with one decimal and drop the "correct count" framing; (b) keep integer "correct"
= count of fully-correct answers (track separately from points); (c) round for display only. **Ask
the founder before implementing** — this is a product/UX call, not a mechanical fix.
**Test:** once decided, `QuizCompleteSummaryTests` cases for a fractional score.

## 54.16 — MCQOptionPicker: tap/voice race + missing animation on voice match
`MCQOptionPicker.swift:48` — `submitAfterDelay` spawns a detached `Task` with **no handle**; if a
voice match (`externalSelectedKey`) lands concurrently with a tap, `onSelect` can fire twice (no
cancellation). Also the row animation keys on local `selectedKey` only (`:41`), so a voice-driven
selection snaps without animation.
**Plan:** hold the `submitAfterDelay` Task in `@State` and cancel it if a voice match arrives (or
guard `onSelect` to fire once); change the `.animation(value:)` key to `effectiveSelectedKey` so a
voice selection animates. **Test:** a VM/inspector test that a concurrent tap+voice-match yields a
single `onSelect`; verify the voice-match animation in-sim.

## Done criteria
- [ ] 54.11 VM field + test; 54.16 single-submit guard + animation; 54.13 **only after** the founder
      decides the fractional-score display.
- [ ] Update parent §54.11/§54.13/§54.16 status.
