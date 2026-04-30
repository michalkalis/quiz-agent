# Issue 19: Auto-confirm of unedited transcript routes through `resubmitAnswer` and errors

**Status:** Triage complete — fix path not yet chosen
**Created:** 2026-04-29
**Surfaced by:** `docs/testing/runs/RS-01-2026-04-29.md` (followup #1)
**Parents:** `issue-18-rs01-end-to-end.md`

## TL;DR for next session

Driving RS-01 to completion exposed a real bug downstream of the asserted
window. ~10 s after the confirmation sheet appears with an unedited transcript,
the auto-confirm timer fires `confirmAnswer()` → `resubmitAnswer(_:suppressAudio:)`.
Two things go wrong, plus a third that masks the first two in `--ui-test` mode:

1. `resubmitAnswer` unconditionally calls `transition(to: .processing)` while
   state is **already** `.processing` (the modal is shown during processing).
   `validTransitions[processing]` does not include `processing` itself, so the
   transition is REJECTED and logged. The state stays at `.processing`, the
   network call still goes out — so this rejection alone is observable in the
   log but not directly user-facing.
2. The mock then returns `QuizResponse.previewStartQuiz` whose `evaluation`
   is `nil`. `handleQuizResponse` fails the `guard let evaluation` and surfaces
   `"Could not evaluate your answer. Please try again."` — this *is* the
   user-facing failure that ends the run.
3. The naming of `resubmitAnswer` is misleading: it was written for "user
   edited the transcript and resubmits", but `confirmAnswer()` falls into it
   for **all** streaming-STT confirmations (because `pendingResponse == nil`
   on that path), so every non-Whisper confirm flows through it.

The next session should pick a fix path (call-site / transition table / mock —
or some combination) and implement it.

## What is already done (don't redo)

| Where | Detail |
|---|---|
| `RS-01-2026-04-29.md` | Reproduction steps, log timeline, exact rejection point |
| `QuizViewModel.swift:80–91` | `validTransitions` table — `.processing` cannot self-transition |
| `QuizViewModel.swift:624–666` | `resubmitAnswer` — calls `transition(to: .processing)` at line 647 |
| `QuizViewModel.swift:804–831` | `handleQuizResponse` — `guard let evaluation` raises the user-facing error |
| `QuizViewModel+Recording.swift:158–182` | `handleCommittedTranscript` — sets state to `.processing` when modal opens |
| `QuizViewModel+Recording.swift:397–414` | `confirmAnswer()` — falls through to `resubmitAnswer` when `pendingResponse == nil` |
| `QuizViewModel+Timers.swift:196–214` | `startAutoConfirmIfEnabled()` — counts down then calls `confirmAnswer()` |
| `UITestSupport.swift:33–52` | Mock wiring: `mockResponse = QuizResponse.previewStartQuiz` |
| `Models/QuizResponse.swift:62–100` | `previewStartQuiz` fixture — `evaluation: nil` |
| `MockNetworkService.submitTextInput` | `NetworkService.swift:700–708` — returns the same `mockResponse` regardless of input |

## What to implement

Three independent issues stack into the failure. Pick the right combination —
the recommended set is **(A) + (C)**, with (B) explicitly rejected.

### (A) Stop redundant `processing → processing` transition in `resubmitAnswer`

**Where:** `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:647`

**The transition is dead code in every modern call site.** `resubmitAnswer`
is reachable only via `confirmAnswer()` (auto-confirm or user tap) and the
edit-then-confirm flow — both of which run while the modal is up, i.e. while
`quizState == .processing`. The `transition(to: .processing)` line therefore
fires after we are already there and is rejected by the table.

**Two reasonable shapes:**

- **A1 — guard the transition:** wrap line 647 with
  `if quizState != .processing { transition(to: .processing) }`.
  Smallest diff, preserves the legacy "called from `.recording`" path if any
  caller still relies on it.
- **A2 — split the function:** factor out a private `submitTranscriptText`
  that performs the text-input network call without touching state, and have
  `resubmitAnswer` call it after `transition(to: .processing)` only when the
  caller is upstream of the modal. Cleaner naming; bigger diff.

A1 is the safer 1-line fix; A2 is the right shape if we also want to rename
`resubmitAnswer` (since it is no longer just for edits).

### (B) DO NOT just add `processing` to `processing.validTransitions`

Tempting because it makes the rejection go away, but the comment on
`validTransitions` is explicit: *"A rejected transition is logged as an error
and is a signal of a bug in the call site."* Adding a self-loop hides the
duplicate-transition design issue. Skip this unless you also rewrite the
comment and accept the new contract.

### (C) Make `MockNetworkService.submitTextInput` return a response with an evaluation

**Where:** `apps/ios-app/Hangs/Hangs/Services/NetworkService.swift:700–708` and
`UITestSupport.swift:40–52`.

Today `submitTextInput` returns the same `mockResponse` (`previewStartQuiz`,
no evaluation) used to start the quiz. After (A) lands, the runtime no longer
errors on the rejected transition — but the mock still has no evaluation, so
`handleQuizResponse` still sets the user-facing error.

**Two reasonable shapes:**

- **C1 — second fixture:** add `QuizResponse.previewAnswerCorrect` (already
  exists at `Models/QuizResponse.swift:102+`) and have `UITestSupport` wire it
  as a separate field on the mock (e.g., `network.mockTextInputResponse`).
  Then `submitTextInput` returns the text-input fixture; everything else keeps
  returning `mockResponse`. Smallest behavior change.
- **C2 — query-aware mock:** make the mock build a synthetic `Evaluation` from
  the `input` parameter and the current `previewStartQuiz` question (Paris
  → correct, anything else → incorrect). More flexible; needed only if a
  future scenario asserts on a specific evaluation result.

Default to **C1**. C2 is only required if RS-XX scenarios test the wrong-answer
path, and that's not yet on the roadmap.

### Verification

Re-run RS-01 end-to-end (same as `docs/testing/runs/RS-01-2026-04-29.md`) and
confirm the post-assertion timeline now reads:

```
recording → processing             (mock auto-emit "Paris", modal up)
processing → showingResult         (auto-confirm fires, mock returns evaluation)
```

with **no** `❌ REJECTED transition` line and **no** `❌ No evaluation in
response` line. Then write the verdict to a new run file
`docs/testing/runs/RS-01-<retest-date>.md` with `VERDICT: PASS` and no
followups.

## Important caveats and traps

- **The two fixes are independent.** (A) without (C) makes the rejected
  transition disappear but leaves the user-facing "Could not evaluate" error
  in `--ui-test` runs. (C) without (A) silences the user-facing error but
  leaves the rejected-transition log noise — it'll keep flagging in every RS-01
  run until (A) lands. Land both together.
- **Production impact of (A) is real.** This rejection has been firing in
  prod every time a streaming-STT user lets the auto-confirm timer run out
  (or taps Confirm without editing). The state machine kept it from corrupting
  state, but the network call still goes out twice in some races. Fix in main,
  not just `--ui-test`.
- **Don't touch the WIP in `AnswerConfirmationView.swift` / `QuestionView.swift`.**
  Same WIP that issue-18 warned about. The fix lives in QuizViewModel and the
  mock — neither view file needs to change.
- **`resubmitAnswer`'s name is wrong now.** Once (A) lands, consider renaming
  to `submitConfirmedTranscript` (or similar) in a follow-up commit. Don't
  bundle the rename with the fix — it makes review harder. Two commits.
- **The `MockSTT` auto-emits "Paris" on recording start** (see RS-01 deviation
  #2). That's why the modal opens before the curl injection has any effect.
  Don't try to "fix" the mock to wait for the curl — RS-01 documents this as
  expected and idempotent.
- **`previewStartQuiz` is the wrong fixture for text input.** It is named for
  the *start-quiz* response. `previewAnswerCorrect` (line 102) already exists
  and includes `evaluation: .previewCorrect` — use it for (C1).

**Memory references:**
- `feedback_root_cause_debugging.md` — fix the wrong call path, don't add a
  self-loop to the transition table
- `feedback_modular_plans.md` — this brief follows that pattern
- `feedback_no_gitflow.md` — commit on main once tested
- `project_crash_elimination.md` — tracks state-machine correctness work; this
  is a small follow-on

## After this issue

1. Re-run RS-01 to confirm the post-assertion path is now clean (one run
   report committed under `docs/testing/runs/`).
2. Consider renaming `resubmitAnswer` to reflect its actual call sites
   (separate commit, after the fix lands).
3. RS-02..RS-05 can then proceed under issue-18's plan with confidence that
   the harness exercises the full happy path, not just up to the assertion
   window.
4. If `submitTextInput` is later expanded to drive new scenarios (e.g.,
   wrong-answer assertions), revisit (C2) to make the mock query-aware.
