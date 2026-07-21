# Issue 118: QuizViewModel façade residuals — give the error axis an owner, move QuizState to its own file

**Triage:** refactor · triaged, needs `/prepare-issue`
**Reversibility:** a
**Created:** 2026-07-21

**Source:** filed from [#113 — QuizViewModel decomposition](issue-113-quizviewmodel-decomposition.md) Session 7, which ran an adversarial hunt for a 6th extract candidate while re-litigating T8's façade gate. Two residual clusters were found, judged real, and deliberately left out of #113's closing commit.

## Why

#113 decomposed the god object into 5 encapsulated children and a 1,620-line façade. That façade is legitimately thin *by delegation* (every extracted domain is a single delegating statement), and its size is dominated by quiz-core flow the plan explicitly assigns to the façade. But the S7 inventory found two clusters that are **not** quiz-core and have no principled reason to sit there:

1. **The error axis has no owner.** #113's own Research axis map names every axis with an owner arrow — *recording* → RecordingCoordinator, *timers* → QuizTimersController, and so on — except one: "*error*: errorMessage, activeErrorModel, lastErrorDebugInfo". It landed on the façade **by omission, not by decision**. The tell: #113's T7 had to invent an "ownerless façade fields get one explicit reset line each" escape hatch specifically because `activeErrorModel` has no child to own its `reset()`.

2. **`QuizState` is a value type living in a class file.** ~77 lines of `QuizViewModel.swift` are a standalone `Sendable` enum plus three extensions (custom `Equatable`, `isShowingResult`/`isError`/`label`, and the `validTransitions` table) with **zero** dependency on the class — no `self`, no stored state, no closures. The legal-transition table is currently findable only by grepping a 1,600-line file.

Neither is urgent. Both are cheap, and both make the next person's life easier.

## Scope

**In:**
- Extract an error owner (working name `ErrorPresenter`) as a 6th `@MainActor ObservableObject` child following #113's locked decisions 2 and 4 — private state, explicit API, injected closures, **no `vm` back-pointer**. Moves: the `ErrorContext` enum, `errorMessage` / `activeErrorModel` / DEBUG `lastErrorDebugInfo`, `setError` + `handleError`, DEBUG `formatDebugError`, `shouldRetryWithNewSession` + `retryLastOperation`. Expose `reset()` and wire it into the façade's `resetState` — replacing T7's explicit `activeErrorModel` reset line.
- Move `QuizState` + its three extensions to `ViewModels/QuizState.swift`. Pure mechanical file move: no injection, no shim, no test re-point, and **no `.stableDump` drift** (value types don't appear in the façade's `@Published` storage).

**Out:**
- Anything #113 already settled. Do not re-litigate the façade line count, `+ScenePhase`, or the permanent decision-2 forward surface — see #113's ⚖ Acceptance entries.
- The submission pipeline (`submitMCQAnswer` / `resubmitAnswer` / `skipQuestion` / `handleQuizResponse` + the re-entrancy guards, ~294 lines). S7 evaluated it as a 7th candidate and **rejected it**: `handleQuizResponse` is the sole writer of 7 quiz-core fields, so extracting it needs 7 quiz-core write closures — reconstructing the shared mutable-state bag through the closure surface, which decision 4 forbids in spirit. It would also create a child→child chain, since RecordingCoordinator already injects all four of these methods. **Do not pursue without new evidence.**
- Error *path* behavior. #112 deduped the quota/429 handling into one canonical `handleError`; this issue relocates that code, it does not change it.

## Notes for prep

- The closure surface for `ErrorPresenter` is **smaller than any of the five children #113 already extracted** — roughly 6 injections (`transition(to:caller:)`, a `quizState` read, `resyncBeforePaywallIfLocallyEntitled`, `presentQuotaPaywall`, `audioService.deactivateSession`, `startNewQuiz`). `activeErrorModel` and `lastErrorDebugInfo` are each written at exactly one site (`setError`) — textbook private-state-with-explicit-API.
- RecordingCoordinator and AudioDeviceState already reach `setError` / `handleError` / `setErrorMessage` through injected closures, so they re-point at the new child with **no signature change**.
- Expect `.stableDump` drift from the `ErrorPresenter` extract (three `@Published` fields move into child storage) — none from the `QuizState` move. Re-record once, per #113 decision 5.
- ⚠️ **Sequencing:** `QuizState` and `ErrorContext` are adjacent at the top of `QuizViewModel.swift`; `ErrorContext` rides along with whichever lands first. Pick an order in prep rather than discovering the overlap mid-run.
- ⚠️ **Do not treat the file move as a way to make a line-count gate go down.** It stands on its own merits (one type per file, the repo's ≤300-line rule, findability). #113 explicitly rejected line-count-driven moves as metric-gaming.
- Residual dead code S7 left alone deliberately: `AudioService.currentOutputDeviceName` (protocol + impl + mock) lost its last consumer when S7 deleted the dead `AudioDeviceState` forward. It was **not** removed because `MockAudioService`'s copy is a *stored* property that appears in the freshly re-recorded snapshot baselines. Fold it into [#116 — AudioService split](issue-116-audioservice-split.md), which re-records those baselines anyway.
