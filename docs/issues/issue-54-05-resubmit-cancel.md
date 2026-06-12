# Plan 54.5 + 54.15 — "Failed to resubmit: cancelled" OOPS screen + ErrorView factory

**Parent:** `issue-54-design-refresh-regressions.md` (§54.5, §54.15) · **Priority:** P0 (founder #6)
**Status:** ready · **Confidence:** high on mechanism (confirm it's the live trigger in-sim)
**Type:** ViewModel async-correctness + error-display routing. These two are one unit — the
cancelled-resubmit case (54.5) is exactly what the ErrorView mis-renders (54.15).

> ⚠️ The implicated VM files were **not** modified by the #52 branch. Confirm the trigger in the
> simulator before changing VM code — the new modal/sheet flow may also contribute.

## 54.5 — self-cancelling auto-confirm Task
**Symptom:** after recording a voice answer, an OOPS screen "Failed to resubmit answer: cancelled"
appears instead of the result screen (founder Image #2). **Streaming-STT path only**; Whisper/batch
path is immune (returns via `pendingResponse` before any cancellation-aware await).

**Mechanism (file:line):**
- `handleCommittedTranscript` (`Hangs/ViewModels/QuizViewModel+Recording.swift:162`) shows the
  confirmation modal and calls `startAutoConfirmIfEnabled()`.
- The auto-confirm Task (`+Timers.swift:202`) runs the countdown then `await self.confirmAnswer()`.
- `confirmAnswer()` (`+Recording.swift:414`) **first calls `cancelAutoConfirm()`** →
  `taskBag.cancel(.autoConfirm)` → **cancels the very Task it is running inside**.
- It then (streaming path, `pendingResponse == nil`) does `await resubmitAnswer(...)` →
  `await networkService.submitTextInput(...)`. URLSession sees the enclosing Task cancelled →
  throws `URLError.cancelled` → caught as the error at `QuizViewModel.swift:652`.

**Fix approach:** don't do cancellation-aware async work inside a Task that cancels itself. Options:
(a) run the actual submission **outside** the auto-confirm Task (e.g. confirmAnswer detaches the
network call, or the auto-confirm Task calls a non-self-cancelling submit), or (b) have the
streaming path reuse a cached response. Pick the one that keeps manual confirm and auto-confirm on
the same submit path. Closely related to the previously-"done" **#19** (auto-confirm routing through
`resubmitAnswer`) — check that fix didn't regress.

**Verification:** behavioural test — auto-confirm on the streaming path reaches `.showingResult`,
not `.error`. Extend `RegressionTests` (or a VM unit test with a mock that records whether the
submit was cancelled). Must fail before the fix. Then sim-repro the real ElevenLabs path.

## 54.15 — ErrorView built inline, bypassing `AppErrorModel.from()`
**Mechanism:** `ContentView.swift:71–79` constructs `AppErrorModel` inline for the `.error` case
with a hardcoded Slovak description and **always** `retryAction: .retryOperation`, ignoring the
`ErrorContext` carried by the state. Consequences: (a) raw English error text (e.g. "cancelled")
shown in a SK-first app; (b) wrong retry action for a `CancellationError`.

**Fix approach:** route through the existing factory `AppErrorModel.from(_:context:)`
(`Hangs/Models/AppErrorModel.swift:29`), which already produces correct SK copy. The `.error` state
must carry the underlying `Error` + `ErrorContext` so `ContentView` can call the factory instead of
hardcoding. Note: `AppErrorModel` has **no dedicated case for `CancellationError`** — once 54.5
stops the spurious cancellation, this is less load-bearing, but add a sensible mapping anyway.

**Verification:** `AppErrorModelTests` already exists — add cases asserting the factory output for a
cancellation/submission context. Confirm ContentView renders SK copy (not raw English) in-sim.

## Pencil 1:1 sync
Error frame `Fwafe` — confirm copy/CTA match the factory output. Batch with the cross-cutting pass.

## Done criteria
- [ ] Streaming auto-confirm reaches the result screen (test red→green; sim-confirmed).
- [ ] ErrorView shows SK copy via `AppErrorModel.from`; retry action correct per context.
- [ ] Update parent §54.5/§54.15 status.
