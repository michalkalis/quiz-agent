# Issue 113: Decompose the QuizViewModel god object

**Triage:** refactor · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 2. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 2 + dimensions 1, 3, 6, 7. Link, don't restate.

## Why

QuizViewModel is a 3,017-line god object across 6 files (main 1519, +Recording 697, +Audio 305, +Timers 219, +CommandListener 203, +ScenePhase 74) owning state and business logic for 8+ screens plus paywall, quota, audio devices, voice commands, and timers — no screen can be understood, tested, or changed in isolation (dim1). The `+Extension` split is file-partitioning, not decomposition: state is deliberately non-private so sibling files can reach in (~12 seam-leak markers, three with explicit "internal for …" comments — dim6). ~36 @Published + ~17 non-observable vars express ~10 independent axes as ~50 free variables; the recording/confirmation clusters are de-facto sub-states of quizState reset by hand at 8+ sites, and `resetState` already silently misses ≥9 fields (dim3). The fix is real encapsulation: extract cohesive sub-objects with private state + explicit API that the façade composes, and fold phase-scoped fields into the phase so leaving it drops its state atomically — closing the reset-drift class of bug structurally rather than by adding more manual resets.

## Scope

**In:**
- Extract 5 sub-objects (see decision 1) with **real** encapsulation — private state, explicit narrow API — composed by a slimmed QuizViewModel acting as a thin state-machine façade that delegates, not a shared mutable-state bag.
- Fold phase-scoped @Published clusters (recording, confirmation) into per-phase `@Published` sub-structs (decision 8) so leaving a phase drops that state atomically; **fix `resetState`'s known misses as a byproduct** of the fold (pendingSkipWindow, activeErrorModel, mcqVoiceMatchedKey, showPaywall, quotaLimitError, commandCapturePhase, consecutiveTranscriptionFailures, autoConfirmCountdown, transcriptWasEdited/preEditTranscript) — not by adding more manual reset lines.
- Derive `score`/`questionsAnswered` as computed over `currentSession` (dim3 :1259) — removes a stale-projection bug in the moved code.
- **Two dim3 cleanups ride along (recommend YES — both sit inside code being moved):** delete the dead write-only-true `autoAdvanceEnabled` axis (:148, pause is covered by currentQuestionPaused → moves with QuizTimersController) and delete `CommandCapturePhase`'s unreachable `.recording/.processing` phases (`CommandCapturePhase.swift:20` → moves with VoiceCommandCoordinator). Both satisfy the target rule "one state machine per axis". Doing them elsewhere would re-touch the same lines.

**Out (explicit non-goals):**
- No behavior changes, no view redesigns — the decomposition is internal; user-visible flows are unchanged (behavior-pinning tests must stay green).
- Prerequisite issues, not this scope: #110 — state-machine enforcement, #111 — navigation-as-owned-state, #112 — error-path dedup. This issue inherits their fixes; it does not redo them.
- AudioService internals — #116 — AudioService split. AudioDeviceState consumes AudioService through its existing protocol facade, unchanged here.
- No `@Observable` macro migration (decision 2) — separate, larger change.

## Resolved design decisions

Each grounded in the Phase-1 research below / the review's dimensions.

1. **5 extracts, not 4.** Research correction 2: +Audio is a de-facto 5th sub-object (owns isPlayingQuestionTTS + the start/stopSilenceDetectionListening choke points + audio-device settings). Extracting only 4 leaves those straddling the boundary. **Commit to 5: EntitlementReconciler, AudioDeviceState, VoiceCommandCoordinator, QuizTimersController, RecordingCoordinator.**
2. **Composition style = façade owns children, views keep binding QuizViewModel.** Children are private/internal `@MainActor ObservableObject`s the façade holds; the façade re-publishes each child's `objectWillChange` and re-exposes each screen's slice via forwarding accessors, so view files keep `@ObservedObject var viewModel: QuizViewModel` and the test surface stays stable. Chosen over views binding children directly because that churns every view file per step and fights the one-screen-at-a-time order for no correctness gain (the encapsulation win — private child state + explicit API — holds regardless of who the view binds to); direct binding is a possible later optimization, out of scope. Repo **stays on ObservableObject** (research verdict: zero `@Observable`/`@Bindable` today; mixing = different DI/binding semantics + migration risk). Snapshot cost is unavoidable either way — the `.stableDump` recurses into child storage — so see decision 5 for handling it once.
3. **Extraction order (by self-containment): EntitlementReconciler → AudioDeviceState → VoiceCommandCoordinator → QuizTimersController → RecordingCoordinator.** EntitlementReconciler is cleanest (all methods in MAIN, only touchpoints +ScenePhase:67 and the +Recording branch #112 removes). AudioDeviceState slots 2nd — its device-management slice is the cleanest screen (AudioDevicePickerView), and pulling the shared audio primitives (TTS flag, silence choke points) out **before** their consumers lets VoiceCommand/Recording inject them per decision 4. RecordingCoordinator is most entangled → last. Research's screen order (AudioDevicePicker → Minimized → Error → Completion → Result → Home → Question) is the per-step **verification lens**: after each object lands, exercise the screens that read its slice, Question (heaviest) verified last.
4. **Shared-state policy — no back-pointers.** `quizState`, `taskBag`, `settings`, `isAppForeground` stay resident on the façade (single source) — **and so do the three verified multi-writer cross-cluster flags: `isAutoRecording` + `isRerecording` (written by both Recording *and* Timers) and `isPlayingQuestionTTS` (written by Audio, read by CommandListener + emitEarcon).** Research ("state that resists single ownership") confirmed these have no single natural owner; they stay façade-resident and children touch them only through injected read/scoped-write closures — never by owning the field. Every other child receives the **minimal** thing it needs — a read closure, a scoped write closure (e.g. `transition(to:)`, `setAudioMode`), or a `taskBag` register/cancel handle — **never a reference to the whole VM**. Rule: *a child may hold injected values/closures, never `weak var vm: QuizViewModel`* — that is exactly what re-creates the god object through the back door.
5. **One extraction = one commit, tests ported, façade shims temporary.** Each object lands as its own commit with its mapped test file ported and green (research maps ~12 VM test files ~1:1 — EntitlementReconcileTests / QuizViewModelTimerTests / SkipCancelWord+CommandListenerTests / QuizViewModelMCQVoiceTests). Façade forwarding shims preserve the old `vm.method()`/`vm.published` API during the transition and are deleted at the end. The 4 `.stableDump` snapshot baselines ({Home,Question,Result,Paywall}) are **re-recorded once as the closing commit** — intermediate commits carry expected snapshot drift (documented in the commit, not chased); the per-step gate is the behavior suite, not the snapshot suite.
6. **Hard prerequisite: run AFTER #115 → #112 → #110 (in that build order).** #115 — iOS 26 raise deletes ~15 nil-branches in these very files; #112 — error dedup removes the +Recording↔paywall coupling (shrinks EntitlementReconciler's cross-touch); #110 — state-machine enforcement makes the transitions this façade relies on actually enforced. Each shrinks the code this issue moves. (#111 — navigation is a sibling prerequisite scope, not a build-order gate.)
7. **New files, each ≤ ~300 lines (repo rule).** Expected: `ViewModels/EntitlementReconciler.swift`, `AudioDeviceState.swift`, `VoiceCommandCoordinator.swift`, `QuizTimersController.swift`, `RecordingCoordinator.swift`, plus a phase-state file (e.g. `QuizState+PhaseState.swift`) for the RecordingState/ConfirmationState sub-structs. The `+Recording/+Audio/+Timers/+CommandListener/+ScenePhase` extension files empty out and are deleted as their contents move; `QuizViewModel.swift` (façade) shrinks well under 300. **Risk flag for Phase 4:** RecordingCoordinator absorbs the 697-line +Recording body — it will likely need an internal split (a confirmation sub-object or private helpers) to hold ≤300; that split is an impl-plan detail.

8. **Phase-state representation = `@Published` sub-structs on the façade, NOT `QuizState` associated values.** Verified against the repo: `QuizState` (`QuizViewModel.swift:22`) is a `Sendable` enum whose recording/confirmation phases (`.recording`, `.processing`) carry **no** associated values, guarded by a custom `Equatable` that deliberately ignores associated values "to preserve animation behavior" plus a `validTransitions: Set<String>` label table. Folding phase data into associated values would force rewriting that Equatable animation contract, the transition table, and every `case .recording`/`if case` match across the codebase — high-risk plumbing churn. `RecordingState`/`ConfirmationState` **sub-structs** held as `@Published` on the façade (each with a `reset()`) are the lower-risk, ObservableObject-compatible choice — a reassigned/mutated `@Published` struct fires `objectWillChange`, consistent with decision 2's ObservableObject-only stance — and touch **no** `QuizState` plumbing.

**Execution note:** this is the largest issue in the arch-review set — Phase 6 must take the **multi-session execution-prompts path** (`issue-113-execution-prompts.md`), one session per extract, not a single flat task list.

**No founder decision needed** — internal refactor with no product-facing surface; composition style (decision 2) is an engineering call. If Phase 4 surfaces a genuine product question, add `**Founder decision needed**` + a default and proceed.

## Tasks (atomic)

> Locked order — **one extract per session** (execution note). Each extract = one commit: mechanical move + its mapped test file(s) ported + green + a temporary façade forwarding shim so `vm.method()`/`vm.published` stays stable. Snapshot drift is expected on every intermediate commit and is only closed in T8 (decision 5). New files land in `ViewModels/`. Phase 6 emits `issue-113-execution-prompts.md` (recon snapshot + one paste-in prompt per session — S1–S5, S6a, S6b, S7 = **8 sessions** below).

**T0 — Standing re-anchor step (every session, before touching any line).** #115 → #112 → #110 rewrite these six files *first*; every `file:line` anchor in this plan and in Research below is a **pre-#115 estimate and WILL be stale**. Each session's first action: re-derive live anchors from the Phase-6 recon snapshot (grep the symbol, never trust a baked line number). Record the pre-extract `wc -l` of all six `QuizViewModel*.swift` files (main + 5 extensions) into the recon snapshot; **their sum is the shrink baseline** — each extract's gate is that this sum strictly decreases. Swift forbids stored properties in extensions, so `@Published` state stays in MAIN and decision 2's forwarding shims are *added* to MAIN — MAIN alone may grow or stay flat; the real shrink is code leaving the six façade files for the new sub-object files, which the sum captures.

**T1 — Extract EntitlementReconciler** — *Session 1, warm-up (cleanest).* Move `reconcileEntitlements` / `syncEntitlementsWithRetry` / `resyncBeforePaywallIfLocallyEntitled` / `refreshUsage` / `notifyPremiumPurchased` + the `showPaywall` / `quotaLimitError` / `usageInfo` state into `EntitlementReconciler.swift` (a `@MainActor ObservableObject` the façade owns and re-publishes). Inject the entitlement/usage service + a `transition(to:)` write closure + a `taskBag` handle; **no `vm` back-pointer.** Touchpoints: `+ScenePhase` foreground-sync call. The `+Recording` 429 branch should already be gone (#112) — if present, STOP: #112 didn't land. Port `EntitlementReconcileTests`.

**T2 — Extract AudioDeviceState** — *Session 2.* Move `+Audio.swift`'s device slice (availableInputDevices / selectedInputDevice / currentIn+OutName computed, showingMicrophonePicker, setPreferredInputDevice / refreshAudioDevices, settings.audioMode + preferredInputDeviceId writes) **and the shared audio primitives** — the start/stopSilenceDetectionListening choke points — into `AudioDeviceState.swift`, so its later consumers (Voice/Recording) inject them rather than straddle the boundary. Per decision 4, `isPlayingQuestionTTS` stays façade-resident; AudioDeviceState writes it via an injected closure. Port `AudioDevicePickerTests`. `+Audio.swift` empties → deleted.

**T3 — Extract VoiceCommandCoordinator** — *Session 3.* Move `+CommandListener.swift` (commandCapturePhase, lastRecognizedCommand, commandAvailability, pendingSkipWindow, voiceStart*Enabled, window/hint refresh, the `routeCommand` dispatch hub, onCommandRecognized / onSkipUndoWindowOpened) into `VoiceCommandCoordinator.swift`. `routeCommand`'s fan-out targets are reached via injected closures (transition, startNewQuiz, skip/undo, submitMCQ…), never a `vm` ref. Port `CommandListenerTests` + `SkipCancelWordTests` (the `CommandCapturePhaseTests` / `StartCommandTests` / `ConfirmResultCommandTests` / `VoiceCommandObservabilityTests` cluster rides along). **Pure move** — dead `.recording`/`.processing` phases are deleted in T6, not here. `+CommandListener.swift` empties → deleted.

**T4 — Extract QuizTimersController** — *Session 4.* Move `+Timers.swift` (answerTimerCountdown, thinkingTimeCountdown, autoAdvanceCountdown, currentQuestionPaused, autoAdvanceEnabled, all countdown start/cancel) into `QuizTimersController.swift`. It writes `isAutoRecording` and calls startRecording / stopRecordingAndSubmit / confirmAnswer / proceedToNextQuestion — all injected as closures; `isAutoRecording`/`isRerecording` stay façade-resident (decision 4). **`autoConfirmCountdown` does NOT move here** — it is confirmation-semantic (declared in MAIN's confirmation block `:133`, read only by AnswerConfirmationView), so it stays façade-resident now and folds into `ConfirmationState` in T7; QuizTimersController only drives its tick via an injected write closure — exactly the `isAutoRecording` pattern (decision 4). Port `QuizViewModelTimerTests` **as-is** (still exercises `autoAdvanceEnabled = false`; that axis dies in T6). `+Timers.swift` empties → deleted.

**T5 — Extract RecordingCoordinator (+ forced internal split)** — *Session 5, heaviest.* Move `+Recording.swift`'s recording + confirmation clusters into an owned `@MainActor ObservableObject`. Its 697-line body exceeds the ≤300 cap, so it **must** split into cohesive same-type files (repo `+Extension` convention):
> - `RecordingCoordinator.swift` (~250) — class + recording-cluster state (isStreamingSTT, speechDetectedDuringAutoRecord, liveTranscript, isStoppingRecording, consecutiveTranscriptionFailures, currentQuestionAudioUrl) + capture lifecycle (toggle/start/startBatch/startStreaming), silence detection, commit watchdog, transcription-failure escalation, audio-interruption/cleanup.
> - `RecordingCoordinator+Submission.swift` (~210) — stopRecordingAndSubmit, submitVoiceAnswer, withUserFacingTimeout (the stop→transcribe→submit path; heaviest single method).
> - `RecordingCoordinator+Confirmation.swift` (~150) — confirmAnswer, begin/cancelEditingTranscript, handleAnswerConfirmationDismissed, rerecordAnswer, cancelProcessing (operate over the confirmation state; the `ConfirmationState` sub-struct itself lands in T7).
> - **Pressure valve:** if `RecordingCoordinator.swift` still lands >300 after the move, split the streaming-STT half (`startSTTEventListener` + `handleCommittedTranscript`) into `RecordingCoordinator+Streaming.swift` (~120).
>
> Reads main-owned submissionEpoch + drives transition / setError / handleQuizResponse — all injected; `isAutoRecording`/`isRerecording`/`isPlayingQuestionTTS` façade-resident (decision 4). Port `QuizViewModelMCQVoiceTests` + the recording cluster (`QuizViewModelStreamingTests`, `QuizViewModelResubmitTests`, `QuizViewModelSubmissionRaceTests`, `QuizViewModelAdvanceRaceTests`, `QuizViewModelReplayContractTests`, `QuizViewModelTTSSpyTests`). `+Recording.swift` empties → deleted.

**T6 — Dead-axis cleanups** — *Session 6a; behavior-changing but safe, isolated from the mechanical moves.* Two deletions on now-relocated code:
> - **autoAdvanceEnabled** (write-only-true; always `true` in prod): delete the property + its two resets, collapse the `QuizTimersController` guard to `!currentQuestionPaused`, and delete the **two ResultView reads — `ResultView.swift:185` (`if viewModel.autoAdvanceEnabled`) and `:271` (`guard viewModel.autoAdvanceEnabled`)**. Update/remove the now-moot `QuizViewModelTimerTests` "no-op when autoAdvanceEnabled is false" test.
> - **CommandCapturePhase dead phases**: delete the unreachable `.recording`/`.processing` cases from `CommandCapturePhase.swift` (now moved with VoiceCommandCoordinator); update `CommandCapturePhaseTests`.

**T7 — Phase-scoped state fold + resetState fix** — *Session 6b.* Fold the recording/confirmation clusters into `RecordingState` / `ConfirmationState` **sub-structs** (decision 8 — *not* `QuizState` associated values), held as `@Published` on the façade in `QuizState+PhaseState.swift`, so **leaving the phase drops that state atomically**. `autoConfirmCountdown` **resides in `ConfirmationState`** (its semantic owner); QuizTimersController keeps writing it through the injected tick closure introduced in T4 — now pointing at the `ConfirmationState` field — never owning it (resolves the Research confirmation-cluster ownership split). Give each sub-struct a `reset()` the façade `resetState`/`transition` invokes — closing the ≥9 known misses (pendingSkipWindow, activeErrorModel, mcqVoiceMatchedKey, showPaywall, quotaLimitError, commandCapturePhase, consecutiveTranscriptionFailures, autoConfirmCountdown, transcriptWasEdited/preEditTranscript) *structurally*, not by adding manual reset lines. Also make `score`/`questionsAnswered` **computed over `currentSession`** (dim3 :1259 — kills the stale-projection bug). Add an anti-drift test: a phase round-trip leaves zero residual across all previously-missed fields.

**T8 — Snapshot re-record + final sweep** — *Session 7, closing commit.* Delete every façade forwarding shim; confirm all 5 extension files are gone and `QuizViewModel.swift` < ~300. Re-record the 4 `.stableDump` baselines ({Home,Question,Result,Paywall}) in **one** commit and verify the diff is **model-restructure-only** (fields moving into child storage), with no view-render change — per `ios.md` "re-record signal, not hard block". Final grep sweep confirms Acceptance globals below.

## Acceptance

> Every check is a shell one-liner or a named suite. "green" = suite passes with **0 skipped**. Line baselines = the pre-extract **sum-of-six** `wc -l` recorded by T0 (`wc -l QuizViewModel*.swift | tail -1`). Run from `apps/ios-app/Hangs/Hangs/ViewModels` unless noted.

**Per-extract** (must hold at that extract's commit):

| Extract | Old extension gone | Sum-of-six shrinks | Mapped tests green | Zero back-pointer | New file(s) ≤ ~300 |
|---|---|---|---|---|---|
| T1 Entitlement | n/a (methods were in MAIN) | `wc -l QuizViewModel*.swift \| tail -1` < T0 sum | `EntitlementReconcileTests` | `grep -c "weak var vm\|viewModel: QuizViewModel" EntitlementReconciler.swift` = 0 | `EntitlementReconciler.swift` ≤ 300 |
| T2 Audio | `! -e QuizViewModel+Audio.swift` | sum < T1 | `AudioDevicePickerTests` | = 0 in `AudioDeviceState.swift` | `AudioDeviceState.swift` ≤ 300 |
| T3 Voice | `! -e QuizViewModel+CommandListener.swift` | sum < T2 | `CommandListenerTests` + `SkipCancelWordTests` | = 0 in `VoiceCommandCoordinator.swift` | `VoiceCommandCoordinator.swift` ≤ 300 |
| T4 Timers | `! -e QuizViewModel+Timers.swift` | sum < T3 | `QuizViewModelTimerTests` | = 0 in `QuizTimersController.swift` | `QuizTimersController.swift` ≤ 300 |
| T5 Recording | `! -e QuizViewModel+Recording.swift` | sum < T4 | `QuizViewModelMCQVoiceTests` + recording cluster | = 0 across `RecordingCoordinator*.swift` | every `RecordingCoordinator*.swift` ≤ 300 |

**Per-session commit gate** (S6a, S6b — each lands as its own commit, verified *at that commit*, **not** deferred to T8):

| Session | Commit gate (all must hold at the session's commit) |
|---|---|
| **S6a** (T6 dead-axis) | `grep -rn "autoAdvanceEnabled" ../../` = 0 (property + its 2 resets + `ResultView.swift:185/:271` reads + the moot timer test all gone) · `grep -n "case recording\|case processing" ../Utilities/CommandCapturePhase.swift` = 0 · `QuizTimersController` guard reads `!currentQuestionPaused` only · `QuizViewModelTimerTests` + `CommandCapturePhaseTests` green, **0 skipped** |
| **S6b** (T7 fold + resetState fix) | anti-drift test passes (phase round-trip → **zero residual** across all ≥9 previously-missed fields) · `score`/`questionsAnswered` computed over `currentSession`, no stored backing · each sub-struct has a `reset()` invoked by façade `resetState`/`transition` · `QuizState+PhaseState.swift` ≤ ~300 · full behavior suite green, **0 skipped** |

**Global (verified at the T8 closing commit):**
- `find . -name "QuizViewModel+*.swift"` returns **nothing** (all 5 extension files deleted).
- `wc -l QuizViewModel.swift` ≤ ~300.
- Full `HangsTests` green — **0 skipped**, no flaky-retry masking (re-run the 3 known async voice tests if red before declaring fail).
- `grep -rn "weak var vm\|var viewModel: QuizViewModel" *Coordinator*.swift *State.swift *Reconciler*.swift` = 0 (decision 4).
- `grep -rn "autoAdvanceEnabled" ../../` = 0 (axis + ResultView reads + tests all gone).
- `grep -n "case recording\|case processing" ../Utilities/CommandCapturePhase.swift` = 0.
- Anti-drift guard test passes: a phase round-trip leaves zero residual for every one of the ≥9 previously-missed fields.
- `score` / `questionsAnswered` are computed properties (no stored backing) over `currentSession`.
- The 4 snapshot baselines are re-recorded in **exactly one** commit whose diff touches only `Snapshots/*` baselines.
- No forwarding shim survives: `grep -rn "façade shim\|forwarding shim" .` = 0.

## Research (Phase 1, 2026-07-20)

Anchors are `ViewModels/QuizViewModel*.swift` unless noted. 38 `@Published` (main) + ~15 non-observable mutable vars → ~10 axes.

**Axis/cluster map** (representative names → target owner):
- *quiz-core* (façade, read by every screen): quizState, currentQuestion, currentSession, score/questionsAnswered (make computed over currentSession — dim3 :1259), sessionCorrect/IncorrectCount, quizStats, streakBeforeLastAnswer.
- *recording* → **RecordingCoordinator**: isStreamingSTT, isAutoRecording, speechDetectedDuringAutoRecord, liveTranscript, isStoppingRecording, isRerecording, consecutiveTranscriptionFailures, currentQuestionAudioUrl.
- *confirmation* → RecordingCoordinator: showAnswerConfirmation, transcribedAnswer, pendingResponse, transcriptWasEdited, preEditTranscript (autoConfirmCountdown is confirmation-semantic but timer-written — **resolved (decision 8, T4+T7): resides in `ConfirmationState`; QuizTimersController drives its tick via an injected write closure, exactly like `isAutoRecording`**).
- *MCQ*: mcqVoiceMatchedKey (+ view-local selectedKey in MCQOptionPicker — dim3 #48 two-sources).
- *paywall/quota* → **EntitlementReconciler**: showPaywall, quotaLimitError, usageInfo.
- *audio devices* → +Audio/AudioDeviceState: availableInputDevices/selectedInputDevice/currentIn/OutName (computed over audioService), showingMicrophonePicker, settings.audioMode/preferredInputDeviceId.
- *timers* → **QuizTimersController**: answerTimerCountdown, thinkingTimeCountdown, autoAdvanceCountdown, autoConfirmCountdown, currentQuestionPaused, autoAdvanceEnabled (dead write-only axis — dim3 #50).
- *minimize*: isMinimized (canMinimize computed). *error*: errorMessage, activeErrorModel, lastErrorDebugInfo + `.error` assoc value (3 stores — dim3 #49, #112 overlap).
- *voice-command* → **VoiceCommandCoordinator**: commandCapturePhase, lastRecognizedCommand, commandAvailability, pendingSkipWindow, voiceStartOnQuestion/HomeEnabled, onCommandRecognized/onSkipUndoWindowOpened. *settings*: settings, showingLanguagePicker. *cross-cut*: isAppForeground, isPlayingQuestionTTS. *guards*: isProcessingResponse, isAdvancing, submissionEpoch, isSubmittingAnswer.
- **resetState (:1419) misses**: pendingSkipWindow, activeErrorModel, mcqVoiceMatchedKey, showPaywall, quotaLimitError, commandCapturePhase, consecutiveTranscriptionFailures, autoConfirmCountdown, transcriptWasEdited/preEditTranscript — folding phase-scoped fields into QuizState assoc-values/sub-structs drops them atomically. Manual reset scattered across 8+ sites (showAnswerConfirmation set at 6 sites alone).

**Extraction seams** (confirmed; two corrections):
- Order of self-containment: **EntitlementReconciler** cleanest — all methods in MAIN (reconcileEntitlements :806, syncEntitlementsWithRetry :827, resyncBeforePaywallIfLocallyEntitled :863, refreshUsage :766, notifyPremiumPurchased :793); only touchpoints = +ScenePhase:67 + the +Recording 429 branch (`+Recording:415/427-428`, which #112 removes). **VoiceCommandCoordinator**: window/hint half is near-pure (`+CommandListener:33/69`); `routeCommand:163` is a dispatch hub — coupling is fan-out, not shared state. **QuizTimersController**: 4 countdown ints clean but writes isAutoRecording + calls startRecording/stopRecordingAndSubmit/confirmAnswer/proceedToNextQuestion — bidirectionally fused with +Recording. **RecordingCoordinator**: most entangled (owns recording+confirmation clusters, reads main-owned submissionEpoch, drives transition/setError/handleQuizResponse).
- **Correction 1:** review's "three `internal for` properties at :134" undercounts — ~12 seam-leak markers in MAIN (props :134/135/136/376/385/407/419/463/466/469/476; methods :322/690/863/1214). The three at :134-136 are the confirmation-cluster subset.
- **Correction 2:** **+Audio is a de-facto 5th sub-object** (owns isPlayingQuestionTTS + the start/stopSilenceDetectionListening choke points called by +Recording/+CommandListener/+ScenePhase + audio-device settings writes). Extracting only the 4 leaves isPlayingQuestionTTS + silence-listening straddling the boundary → Phase-2 scope decision: 4 vs 5 extracts (recommend 5).
- **State that resists single ownership (stays shared on façade / injected):** quizState (via transition()), taskBag (all seams register TaskKeys; resetState blanket-cancels), settings (read by all, written by +Audio), isAppForeground (+ScenePhase writes; +Recording/+Audio/+CommandListener read), isAutoRecording/isRerecording (+Recording & +Timers write), isPlayingQuestionTTS (+Audio writes; +CommandListener + emitEarcon read).

**Screen→@Published slices** (all `@ObservedObject var viewModel: QuizViewModel`) — for "one screen at a time" order:
- AudioDevicePickerView → *audio* only (availableInputDevices, selectedInputDevice, selectedAudioMode, setPreferredInputDevice, refreshAudioDevices). Cleanest.
- MinimizedQuizView → *quiz-core* + *minimize* (currentSession, questionsAnswered, score, quizState, isMinimized, endQuiz). Small.
- ErrorView (inside `ContentView.swift`) → *error* + *paywall* + *quiz-core* (activeErrorModel, lastErrorDebugInfo, showPaywall, quotaLimitError, quizState, shouldRetryWithNewSession, isMinimized, retryLastOperation, resetToHome, startNewQuiz).
- CompletionView → *quiz-core* + *paywall* (quizStats, score, sessionCorrect/Incorrect, questionsAnswered, currentSession, usageInfo, presentPaywall, refreshUsage, resetToHome, startNewQuiz).
- ResultView → *quiz-core* + *timers* + *minimize* (resultQuestion/Evaluation, score, autoAdvanceCountdown/Enabled, currentQuestionPaused, pauseQuiz/resumeAutoAdvance/continueToNext, canMinimize, commandListenerHint).
- HomeView → *paywall* + *audio* + *voice* (quizState, usageInfo/presentPaywall/refreshUsage, refreshAudioDevices/showingMicrophonePicker, commandListenerHint/voiceStartOnHomeEnabled/refreshCommandWindow, startNewQuiz).
- QuestionView (heaviest, LAST) → *recording* + *confirmation* + *MCQ* + *timers* + *quiz-core* + *minimize* + *audio* (toggleRecording, rerecordAnswer, isStreamingSTT, liveTranscript, showAnswerConfirmation, transcribedAnswer, autoConfirmCountdown, confirm/begin/cancelEditingTranscript, resubmitAnswer, cancelProcessing, mcqVoiceMatchedKey, submitMCQAnswer, answer/thinkingTimeCountdown, canReplayAudio/replayQuestionAudio/toggleMute, …).
- PaywallView binds StoreManager only — **no QuizViewModel** (dim1 #25 confirmed). AnswerConfirmationView is a subview with no direct VM ref (bindings passed in).
- **Split order:** AudioDevicePicker → MinimizedQuiz → ErrorView (coordinate w/ #112) → Completion → Result → Home → Question.

**Test/snapshot risks:**
- ~12 QuizViewModel test files (anchor `QuizViewModelTests.swift`, 1200 lines); pin *behavior* (state transitions, submission races via submissionEpoch, timer countdowns + taskBag keys, MCQ voice match, entitlement single-flight/backoff, skip cancel-word). EntitlementReconcileTests / QuizViewModelTimerTests / SkipCancelWordTests+CommandListenerTests / QuizViewModelMCQVoiceTests map ~1:1 to the four extracts — port alongside. Tests call `vm.method()` / read `vm.published` directly → each moved API needs a façade forwarding shim or test updates.
- **Snapshot gotcha** (memory `project_ios_ci_snapshot_and_flaky_async`): `Snapshots/{Home,Question,Result,Paywall}ViewSnapshotTests` use `.stableDump` (`Support/SnapshotHelpers.swift`) which `Swift.dump()`s the whole view → recurses into QuizViewModel `@Published` storage. Any add/remove/move of `@Published` fields changes the dump → baseline diff. Decomposition WILL require re-recording all 4 baselines (intentional structural change = re-record, not regression).

**#110/#112/#115 interaction (same files):** #110 fixes state-machine bypasses (:555/1069/1379) — run BEFORE so decomposition inherits enforced transitions. #112 folds the quota/429 branch into one handleError — removes the +Recording↔paywall coupling, shrinking EntitlementReconciler's cross-touch. #115 raises to iOS 26 → deletes ~15 nil-branches (silenceDetectionService non-optional). Confirmed sequence #115→#112→#110→#113.

**Prior-art — build-vs-adopt:** Repo is uniformly `ObservableObject` — 6 classes (QuizViewModel, OrderPackViewModel, OnboardingViewModel, AppState, StoreManager, MockAudioService); **zero `@Observable` macro, zero `@Bindable`**; Views use @StateObject/@ObservedObject/@EnvironmentObject. **Lowest-risk target: stay on ObservableObject** — compose child `@MainActor ObservableObject`s the façade owns; Views bind to sub-VMs via @ObservedObject (or façade re-exposes). Do NOT introduce `@Observable` (mixing = different DI/binding semantics + migration risk); an `@Observable` migration is a separate, larger change, out of scope here.

**Web pass skipped:** default OFF; internal-only refactor, no external library/API question.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND 0.84 |
| 4 · Impl-plan         | ✅ done | — |
| 5 · Impl-plan review  | 🔄 re-gate | cycle 1: ready-check NOT-READY (2) · design-soundness UNSOUND 0.72 (1) — fixed, re-gate |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 14:20 · **Next:** Phase 5 re-gate (cycle 2) · **Gate attempts:** P3 1/3 (passed) · P5 1/3
