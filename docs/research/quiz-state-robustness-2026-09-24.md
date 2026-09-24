# Quiz state robustness: research and direction (2026-09-24)

**Question:** why do quiz-screen states occasionally "break" (e.g. the voice-answer confirmation sheet showing up on the *next* question), and what architecture direction fixes this class of bug for good, adopted incrementally with no big rewrite before launch?

**TL;DR.** Adding more single-purpose guards won't fix this. The root cause is that **async results are not tied to the question (and attempt) that started them**. Guards compare the *phase label* (`== .processing`) and not *which* question owns the phase, so a late callback from question N passes a guard during question N+1. Recommended direction: **(1) one ownership token per question attempt, checked at every async write-back, plus a field flight recorder. (2) A seeded random event-sequence test harness with invariants. (3) Later, fold the confirmation and capture booleans into the state enum. Do not adopt TCA.**

## 1. What exists today (recon, main @ 4469f38b)

| Area | Where | State |
|---|---|---|
| Phase enum | `ViewModels/QuizViewModel.swift:23` `QuizState` (10 cases, `.showingResult` / `.error` carry data) | Good base |
| Transition table | `QuizState.validTransitions` → `Set<String>` of labels. `transition(to:caller:)` at `QuizViewModel.swift:455` rejects illegal moves, logs, runs phase-exit side effects, sends Sentry breadcrumb + `SentryLog` | Enforced single gate, but string-typed |
| Equality | Custom `Equatable` compares **case only**, ignoring associated values (for animation) | Guards can't tell question N from N+1 |
| Sub-state | `RecordingState` / `ConfirmationState` structs (`QuizState+PhaseState.swift`). `showAnswerConfirmation`, `isEvaluatingAnswer`, `noAnswerCaptured` … are **booleans next to** the phase. About 32 `is*/show*` Bool vars across `ViewModels/` | Orthogonal flags, so illegal combinations can be represented |
| Task ownership | `Concurrency/TaskBag.swift`: 23 `TaskKey`s, add-cancels-previous, `cancelAll()` on reset | Good (TCA-style cancel IDs, hand-rolled) |
| Stale guards | `submissionEpoch` (#79 typed-answer voice race) covers only the committed-voice-transcript path. `isProcessingResponse`, `isAdvancing`, `isSubmittingAnswer`, `isStarting` single-flight Bools. State-label rechecks after `await` | Each bug added a guard of a different shape (#79, #110 state-machine enforcement, #133 V14, #179 stall watchdog) |
| Time | swift-clocks injected everywhere (#180 track A), `TestClock` in tests | Enables deterministic sequence tests |
| Tests | 128 files in `HangsTests/`: `QuizViewModelTransitionGuardTests` (rejections change nothing), `…AdvanceRaceTests`, `…SubmissionRaceTests`, `RerecordDuringSubmitTests`, `SubmissionStallTests`, `AudioSessionNotificationTests` (#180 track G), RS-01..21 XCUITest (#180 track D) | Hand-picked interleavings only. No generated sequences |

### Concrete stale-write paths (likely cause of "confirmation sheet on the next question", **unverified**)

- `RecordingCoordinator+Submission.swift:181`: the voice-submit result applies if `quizState() == .processing`. The captured `answeredQuestionId` (`:142`) is sent to the backend but **never compared with the current question** before the sheet opens.
- `RecordingCoordinator+Submission.swift:154` and `:222` (no evaluation / HTTP 400), `ScenePhase.swift:103`, and the commit watchdog (`Capture.swift:364`) all call `handleTranscriptionFailure()` (`Capture.swift:406`). That function has **no ownership check**: from `.askingQuestion` it takes the *legal* edge `askingQuestion → processing` and opens the empty "no answer" sheet. So a late 400 or no-evaluation response from question N, arriving after the advance to N+1, would put the confirmation sheet on N+1. The task is cancelled only on explicit paths (`taskBag.cancel(.voiceSubmission)` in resubmit / re-record / cancel), and `await MainActor.run { … }` does not re-check `Task.isCancelled`.
- `presentVoiceTranscript` (`ReadBack.swift:26`) sets `showAnswerConfirmation = true` unconditionally and trusts its callers.
- Rejected transitions log only to OSLog (`Logger.quiz.error`), which **can't be retrieved from a field device after the fact** (OSLogStore reads the current process only [S14]). The one signal that says "a stale path fired" never reaches Sentry.

A pinning test should confirm the hypothesis: submit a voice answer on Q1 → advance to Q2 → resolve the Q1 mock with a 400 → assert that no sheet appears on Q2.

## 2. What the research says

**2.1 One state value, a pure transition function.** Harel's statecharts [S1] and statecharts.dev [S2][S3] model reactive UIs as one current state plus explicit event→transition rules. Hierarchy and orthogonal regions keep this from turning into state explosion. Khourshid [S4] shows the typical failure mode: behavior guarded by booleans ("is the button disabled?") instead of by state, so every new async source adds another flag and another uncovered combination. That describes the ~32 flags here. The Elm architecture [S5] and TCA [S6] are the unidirectional versions: `(State, Event) → (State, Effects)`, with effects fed back as events.

**2.2 Make illegal states unrepresentable.** Minsky [S7] and Feldman [S8]: encode "sheet visible only while confirming *this* question's answer" in the type, e.g. `.processing(.confirming(attempt, transcript))`, so it can't be violated. In Swift this means enums with associated values and exhaustive `switch`. Today `showAnswerConfirmation == true` while `quizState == .askingQuestion` is representable. The type should rule it out.

**2.3 Stale-effect protection: ownership and cancellation.**
- Apple's actor-reentrancy guidance (WWDC21 [S9]): "check your assumptions across each await". Mutate state in synchronous code, and assume the world moved on while you were suspended.
- Structured concurrency [S10]: tasks have an owner, and cancellation is cooperative. Cancelling does **not** stop a continuation that is already scheduled from writing state unless it checks. SwiftUI's `.task(id:)` [S11] ties work to an identity and cancels it when the identity changes. That is the same idea as a per-question token.
- TCA effect IDs [S12] (`cancellable(id:cancelInFlight:)`): every long-lived effect has a key, and starting a new one or leaving a state cancels it. `TaskBag` already implements this.
- React's "ignore flag" [S13]: even with cancellation in place, *every* async write-back checks that it still belongs to the current request. Cancellation saves work, the identity check guarantees correctness, and robust systems use both. Here cancellation exists but the identity check (`questionId` + attempt) is missing.

**2.4 Observability: a flight recorder.** Log *inputs* (events), not only resulting transitions, with the owning question/attempt ID. The trail then shows *why* a transition happened and can be replayed. This is the event-sourcing idea [S15]. Sentry keeps 100 breadcrumbs by default and can attach files to events [S16]. OSLog can't be pulled from a user device later [S14], so the recorder must be in-app (ring buffer → Sentry attachment and the feedback flow).

**2.5 Testing a state machine.**
- *Transition-table tests*: parameterized Swift Testing [S17] over every (state, event) pair. Pins what the table claims.
- *Exhaustive state assertions*: TCA's `TestStore` fails if a state change or an in-flight effect is not asserted [S6][S18]. The value is in "unasserted effects fail the test", which works without TCA.
- *Model-based / stateful property testing*: generate random event sequences, run them, check invariants after every step, shrink failures to a minimal sequence. QuickCheck state machines found deep bugs at Ericsson, Klarna, Volvo, and Dropbox [S19][S20]. Hypothesis `RuleBasedStateMachine` + `@invariant` is the clearest reference design [S21]. XState derives test paths from the machine graph [S22]. In Swift, SwiftCheck [S23] looks unmaintained. `x-sheep/swift-property-based` targets Swift Testing with shrinking [S24]. A hand-rolled seeded generator is also enough.
- *Deterministic simulation*: FoundationDB runs the whole system single-threaded under a deterministic scheduler with injected faults, so any failure replays exactly from its seed [S25]. Here that means main-actor VM + `TestClock` + mocks + seeded RNG. #180 track A already provides the clock and the serial executor.
- *Field replay*: a flight-recorder event log in the same event vocabulary as the generator turns a TestFlight report into a deterministic regression test.

## 3. Adoption path for this codebase

Effort is relative (S = one focused PR touching a few files; M = a few PRs; L = multi-session restructure).

| Stage | What | Prevents | Effort |
|---|---|---|---|
| **1. Ownership token + flight recorder** | One `AttemptID` (question ID + monotonic attempt counter) replaces or absorbs `submissionEpoch`, bumped on question entry and on every submit / re-record / skip. Every async continuation captures it at start and goes through one `isCurrent(attempt)` check before *any* state write (voice submit, failure funnel, read-back, watchdog, STT events, deferred advance). Stale drops and rejected transitions go to `SentryLog` (not only OSLog). An in-memory ring buffer (~200) of *events* (input + attempt + phase + key flags) is attached to Sentry events and TF feedback. DEBUG-only invariant checks after each transition (`assertionFailure`, release = log + Sentry), e.g. sheet visible ⇒ `.processing` for the current attempt; mic live ⇒ `.recording`; `.showingResult.question.id == currentQuestion.id` | The whole "late result from question N lands on N+1" family, including the confirmation-sheet symptom. Makes future field breakages diagnosable | **S** |
| **2. Random event-sequence harness** | A test-only driver over the real `QuizViewModel` with existing Fixtures/mocks + `TestClock`. Event vocabulary: taps, speech start/stop, STT commit/partial, network ok/400/timeout/late (per attempt), timer ticks, audio interruption/route change, background/foreground, voice commands, MCQ tap. N seeds per CI run, invariants from Stage 1 checked after every step, failure prints seed + event list, shrinking by deleting events. The same vocabulary replays Stage 1 field logs as regression tests | Unknown interleavings found before TF instead of in the car. Encodes the invariants as a living spec | **M** |
| **3. Fold flags into the enum** | Replace orthogonal Bools with associated values, one cluster at a time, confirmation cluster first: `.recording(AttemptID)`, `.processing(AttemptID, ProcessingPhase)` with `.uploading \| .confirming(transcript, noAnswer) \| .evaluating`. `validTransitions` keyed by a case enum, not `String`. Keep the case-only `Equatable` for animation, add an explicit `sameOwner` check for guards. Views read derived properties (as `resultQuestion` does today) | Illegal combinations become unrepresentable. Stage 1 invariants become compile-time facts | **M–L** (per cluster; do it when a cluster is touched anyway) |
| **4. Pure reducer core (optional)** | Hand-rolled `reduce(State, Event) -> (State, [Effect])` for the quiz flow. A thin runner executes effects under `TaskBag` keys and feeds results back as events tagged with `AttemptID`. Coordinators become effect executors | Whole bug class structurally. Enables exhaustive TestStore-style tests without TCA | **L**; only if 1–3 still leak |

**Why this order:** Stage 1 is cheap, targets the observed symptom, and produces both the invariants and the event vocabulary that Stage 2 needs. Stage 2 then shows empirically whether Stage 3/4 are still needed. That keeps the big restructures evidence-driven.

## 4. Recommendation

Do **Stage 1 now** (it is a correctness fix in the driving loop, small and reviewable), and **Stage 2 right after**, seeded from the hypothesis above as its first known-bad sequence. Do Stage 3 opportunistically: the confirmation cluster first, the next time #184 read-back or the sheet UX is touched. Decide on Stage 4 only if the Stage 2 harness keeps finding bugs after Stage 3. Don't plan it for the launch version.

Success criteria for Stage 1+2: the "late 400 from Q1 during Q2" test fails on current main and passes after the change. The random harness runs ≥ 500 seeded sequences per CI run with zero invariant violations. Every stale drop in TF shows up in Sentry with its attempt ID.

## 5. What NOT to do

- **Don't adopt TCA wholesale.** It means rewriting a ~2.4k-line façade plus four coordinators into a new paradigm right before launch, with a heavy dependency and a new mental model for every future agent session. It also brings its own sharp edges (e.g. the cancel-ID pruning bug that forced an API deprecation [S26]). The benefits come from its *ideas* (single state, effect IDs, exhaustive effect assertions), and `TaskBag` + `transition()` already hold half of them.
- **Don't keep patching per bug with a new flag.** #79, #110, #133 V14, and #179 each added a guard of a different shape. A fifth Bool for "sheet belongs to this question" repeats the pattern. One ownership token is the structural fix.
- **Don't rely on phase-label equality for ownership.** `== .processing` is true for every question. Compare identity.
- **Don't treat cancellation as sufficient.** A cancelled task's already-scheduled `MainActor.run` still writes. Always pair cancellation with the identity check [S13].
- **Don't put flow state in SwiftUI view-local `@State`** (the #110 MCQ lesson), and don't gate behavior on "button disabled" [S4].
- **Don't depend on OSLog for field debugging** [S14]. It isn't retrievable later.
- **Don't introduce an external statechart DSL/codegen** (XState-style) for Swift. There's no mature Swift toolchain, and an enum + table + tests gives the same guarantees here.
- **Don't let the random harness use wall-clock sleeps or parallel test execution.** Both were ruled out in #180 track A.

## Sources

- [S1] Harel, *Statecharts: A visual formalism for complex systems*, Sci. Comput. Program. 8(3), 1987 — https://www.sciencedirect.com/science/article/pii/0167642387900359
- [S2] statecharts.dev, *Welcome to the world of Statecharts* — https://statecharts.dev/
- [S3] statecharts.dev, *State machine: state explosion* — https://statecharts.dev/state-machine-state-explosion.html
- [S4] D. Khourshid, *No, disabling a button is not app logic* (2019) — https://dev.to/davidkpiano/no-disabling-a-button-is-not-app-logic-598i
- [S5] *The Elm Architecture* — https://guide.elm-lang.org/architecture/
- [S6] Point-Free, *swift-composable-architecture* — https://github.com/pointfreeco/swift-composable-architecture
- [S7] Y. Minsky, *Effective ML Revisited*, Jane Street — https://blog.janestreet.com/effective-ml-revisited/
- [S8] R. Feldman, *Making Impossible States Impossible*, elm-conf 2016 — https://www.youtube.com/watch?v=IcgmSRJHu_8
- [S9] Apple WWDC21, *Protect mutable state with Swift actors* (reentrancy) — https://developer.apple.com/videos/play/wwdc2021/10133/
- [S10] Apple WWDC21, *Explore structured concurrency in Swift* — https://developer.apple.com/videos/play/wwdc2021/10134/
- [S11] Apple, SwiftUI `task(id:priority:_:)` — https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)
- [S12] TCA, `cancellable(id:cancelInFlight:)` — https://pointfreeco.github.io/swift-composable-architecture/main/documentation/composablearchitecture/effect/cancellable(id:cancelinflight:)/
- [S13] React docs, *Synchronizing with Effects: fetching data* (ignore-flag race fix) — https://react.dev/learn/synchronizing-with-effects#fetching-data
- [S14] Apple, `OSLogStore` — https://developer.apple.com/documentation/oslog/oslogstore ; limits discussed at https://developer.apple.com/forums/thread/691093
- [S15] M. Fowler, *Event Sourcing* — https://martinfowler.com/eaaDev/EventSourcing.html
- [S16] Sentry for iOS, options (`maxBreadcrumbs` default 100) — https://docs.sentry.io/platforms/apple/guides/ios/configuration/options/ ; attachments — https://docs.sentry.io/platforms/apple/guides/ios/enriching-events/attachments/
- [S17] Apple, Swift Testing parameterized tests — https://developer.apple.com/documentation/testing/parameterizedtesting
- [S18] Point-Free, *Non-exhaustive testing in the Composable Architecture* — https://www.pointfree.co/blog/posts/83-non-exhaustive-testing-in-the-composable-architecture
- [S19] J. Hughes, *Experiences with QuickCheck: Testing the Hard Stuff and Staying Sane* (2016) — https://link.springer.com/chapter/10.1007/978-3-319-30936-1_9
- [S20] Mysteries of Dropbox: property-based testing of a distributed sync service — https://www.researchgate.net/publication/305508005_Mysteries_of_DropBox_Property-Based_Testing_of_a_Distributed_Synchronization_Service
- [S21] Hypothesis, *Stateful tests* (`RuleBasedStateMachine`, `@invariant`) — https://hypothesis.readthedocs.io/en/latest/stateful.html
- [S22] Stately, `@xstate/graph` (model-based test paths) — https://stately.ai/docs/xstate-graph
- [S23] typelift/SwiftCheck — https://github.com/typelift/SwiftCheck
- [S24] x-sheep/swift-property-based (Swift Testing, shrinking) — https://github.com/x-sheep/swift-property-based
- [S25] FoundationDB, *Simulation and Testing* — https://apple.github.io/foundationdb/testing.html
- [S26] TCA discussion #2092, type-name cancel IDs deprecated (release-build pruning bug) — https://github.com/pointfreeco/swift-composable-architecture/discussions/2092
