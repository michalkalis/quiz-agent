# Issue #113 — Execution plan + ready-to-paste session prompts

**Created:** 2026-07-20 — from the prepared #113 plan (Phase 6 split of `/prepare-issue`). #113 is the **largest issue in the arch-review set**: decompose the 3,017-line `QuizViewModel` god object (6 files) into 5 real-encapsulation sub-objects + a unified reset model + a snapshot re-record. Split into **8 sequential, independently-committable sessions** (S1–S5, S6a, S6b, S7). Each block below is self-contained: open a fresh session, paste the fenced block, go. The codebase is mapped in the Recon snapshot — sessions do **not** re-map.

> Parent plan: [`issue-113-quizviewmodel-decomposition.md`](issue-113-quizviewmodel-decomposition.md). Source: [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 2.

> **HARD PREREQUISITE (gates every session):** run **only AFTER #115 → #112 → #110 land, in that build order** (decision 6). #115 (iOS 26 raise) deletes ~15 nil-branches in these files; #112 (error dedup) removes the +Recording↔paywall coupling; #110 (state-machine enforcement) makes the transitions this façade relies on actually enforced. Each rewrites the files this issue moves, so **every `file:line` below is a pre-#115 estimate and WILL be stale — grep the symbol, never trust a baked line number.** If any prerequisite is unmerged, STOP.

---

## Recon snapshot — what the codebase already gives us

**Target files (`apps/ios-app/Hangs/Hangs/ViewModels/`):** the six façade files, **pre-prerequisite** `wc -l` (reference only — the real **sum-of-six baseline is re-recorded by S1** *after* #115/#112/#110 land):

- `QuizViewModel.swift` 1519 · `QuizViewModel+Recording.swift` 697 · `QuizViewModel+Audio.swift` 305 · `QuizViewModel+Timers.swift` 219 · `QuizViewModel+CommandListener.swift` 203 · `QuizViewModel+ScenePhase.swift` 74 → **3017 total**. New sub-object files land in `ViewModels/`. `Utilities/CommandCapturePhase.swift` → **moves to `ViewModels/CommandCapturePhase.swift` in S3** (T3).
- Swift forbids stored properties in extensions → `@Published` state stays in MAIN; decision-2 forwarding shims are *added* to MAIN, so MAIN alone may grow/stay flat. The shrink is code leaving the six files for the new files — **the sum-of-six captures it; each extract's gate is that the sum strictly decreases.**

**Symbol → owner map (grep these symbols, not line numbers):**

- **EntitlementReconciler** (S1): `reconcileEntitlements` / `syncEntitlementsWithRetry` / `resyncBeforePaywallIfLocallyEntitled` / `refreshUsage` / `notifyPremiumPurchased` + `showPaywall` / `quotaLimitError` / `usageInfo`. Touchpoint = +ScenePhase foreground-sync. The +Recording 429 branch should be **gone via #112** — if present, STOP (#112 didn't land).
- **AudioDeviceState** (S2): `availableInputDevices` / `selectedInputDevice` / `currentIn`+`currentOutName` / `showingMicrophonePicker` / `setPreferredInputDevice` / `refreshAudioDevices` / `settings.audioMode`+`preferredInputDeviceId` **+ the `start`/`stopSilenceDetectionListening` choke points** (pulled out first so Voice/Recording inject them). `isPlayingQuestionTTS` stays façade-resident; AudioDeviceState writes it via injected closure.
- **VoiceCommandCoordinator** (S3): `commandCapturePhase` / `lastRecognizedCommand` / `commandAvailability` / `pendingSkipWindow` / `voiceStart*Enabled` / window+hint refresh / the `routeCommand` dispatch hub / `onCommandRecognized` / `onSkipUndoWindowOpened`. Fan-out targets reached via injected closures. **`CommandCapturePhase.swift` moves `Utilities/`→`ViewModels/` here.**
- **QuizTimersController** (S4): `answerTimerCountdown` / `thinkingTimeCountdown` / `autoAdvanceCountdown` / `currentQuestionPaused` / `autoAdvanceEnabled` + countdown start/cancel. Writes `isAutoRecording`; drives `autoConfirmCountdown`'s tick via injected closure but does **not** own it (it stays façade-resident until S6b).
- **RecordingCoordinator** (S5, heaviest — forced internal split): recording + confirmation clusters → `RecordingCoordinator.swift` (~250) + `+Submission.swift` (~210) + `+Confirmation.swift` (~150); pressure valve `+Streaming.swift` (~120) if the base still lands >300.

**Shared-state — façade-resident, injected as read/scoped-write closures, NEVER owned by a child (decision 4):** `quizState` (via `transition()`), `taskBag`, `settings`, `isAppForeground`, `isAutoRecording`/`isRerecording` (Recording *and* Timers write), `isPlayingQuestionTTS` (Audio writes; CommandListener + emitEarcon read). **Rule: a child holds injected values/closures, never `weak var vm: QuizViewModel` — that back-door re-creates the god object.**

**Test map (`HangsTests/`, Swift Testing) — port alongside each extract:** S1 `EntitlementReconcileTests` · S2 `AudioDevicePickerTests` · S3 `CommandListenerTests` + `SkipCancelWordTests` (`CommandCapturePhaseTests`/`StartCommandTests`/`ConfirmResultCommandTests`/`VoiceCommandObservabilityTests` ride along) · S4 `QuizViewModelTimerTests` · S5 `QuizViewModelMCQVoiceTests` + recording cluster (`QuizViewModelStreamingTests`/`ResubmitTests`/`SubmissionRaceTests`/`AdvanceRaceTests`/`ReplayContractTests`/`TTSSpyTests`). Tests call `vm.method()`/read `vm.published` → each moved API needs a **temporary** façade forwarding shim tagged with the exact marker `// TRANSITION-SHIM(#113)` (S7 greps it → 0). Decision-2 permanent slice-forwarding accessors are **untagged**.

**Snapshot gotcha** (memory `project_ios_ci_snapshot_and_flaky_async`): `Snapshots/{Home,Question,Result,Paywall}ViewSnapshotTests` use `.stableDump` (`Support/SnapshotHelpers.swift`) → recurse into `@Published` storage → any add/remove/move of a `@Published` field diffs the baseline. **Drift is EXPECTED on every intermediate commit and is only closed in S7** (decision 5). Per-step gate = the **behavior** suite, not the snapshot suite.

**S6b computed-`score`/`questionsAnswered` fan-out** (each direct assignment → `Fixtures.session(score:answered:)`; **grep the assignment, don't trust the number**): `QuizViewModel.swift` previews + `CompletionView.swift` (production); `QuizViewModelTests` / `CompletionViewInspectorTests` / `ResultViewInspectorTests` / `Snapshots/ResultViewSnapshotTests` (tests). ⚠️ The fan-out **also catches `QuizViewModel.swift:1440-1441`** — `resetState`'s `score = 0`/`questionsAnswered = 0` — which become **deletions** (not fixture migrations) once the stored backing is gone.

---

## Locked decisions (verbatim by id from the parent plan — carry into every session)

| # | Decision |
|---|---|
| **1** | **5 extracts, not 4:** EntitlementReconciler, AudioDeviceState, VoiceCommandCoordinator, QuizTimersController, RecordingCoordinator. |
| **2** | **Façade owns children; views keep binding `QuizViewModel`.** Children are `@MainActor ObservableObject`s the façade holds and re-publishes; permanent slice-forwarding accessors keep the view/test surface stable. Repo **stays on ObservableObject** — no `@Observable`/`@Bindable`. |
| **3** | **Extraction order (self-containment):** Entitlement → AudioDevice → VoiceCommand → Timers → Recording. Pull shared audio primitives out (S2) before their consumers. |
| **4** | **No back-pointers.** Shared multi-writer state stays façade-resident; children get injected values/closures, **never** `weak var vm`. |
| **5** | **One extract = one commit**, mapped tests ported + green, façade forwarding shims temporary (`// TRANSITION-SHIM(#113)`), 4 snapshot baselines re-recorded **once** in S7. |
| **6** | **Run AFTER #115 → #112 → #110** (build order). #111 is a sibling scope, not a build-order gate. |
| **7** | **New files ≤ ~300 lines.** RecordingCoordinator must split internally (S5). |
| **8** | **Phase-state = `RecordingState`/`ConfirmationState` sub-structs private inside RecordingCoordinator**, not `QuizState` associated values. Each with its own `reset()`; `autoConfirmCountdown` resides in `ConfirmationState`. |

---

## Session breakdown

| Session | Task | Risk | Depends on / blocks |
|---|---|---|---|
| **S1** | T1 EntitlementReconciler (warm-up, cleanest) | Low | prereqs merged → blocks S2. Records the sum-of-six baseline. |
| **S2** | T2 AudioDeviceState (+ shared audio primitives) | Low–Med | S1 → blocks S3 |
| **S3** | T3 VoiceCommandCoordinator (+ CommandCapturePhase file move) | Med | S2 → blocks S4 |
| **S4** | T4 QuizTimersController | Med | S3 → blocks S5 |
| **S5** | T5 RecordingCoordinator (+ forced internal split; heaviest) | High | S4 → blocks S6a |
| **S6a** | T6 dead-axis cleanups (autoAdvanceEnabled + CommandCapturePhase dead phases) | Low–Med | S5 → blocks S6b |
| **S6b** | T7 unified reset model + resetState fix + computed score/answered | Med–High | S6a → blocks S7 |
| **S7** | T8 snapshot re-record + final sweep (shim removal, globals) | Low | S6b (closing commit) |

**Strictly sequential** (each depends only on the prior, already-merged session — the extracts inject each other's primitives per decision 3). No parallel sessions.

---

## Standing gate (applies to EVERY session — the fenced prompts reference this, don't repeat it)

1. **Prereq check (first action):** confirm #115 → #112 → #110 are all merged. If not, STOP and report.
2. **T0 re-anchor (first action):** every `file:line` in the plan/recon is a pre-#115 estimate — **re-derive live anchors by grepping the symbol**, never trust a baked number. **S1 records the post-prereq sum-of-six** `wc -l QuizViewModel*.swift | tail -1` into this file's Status as the shrink baseline; every later session re-reads it.
3. **Per-extract commit gate (S1–S5, verified at that commit):** old extension file gone (n/a for T1) · `wc -l QuizViewModel*.swift | tail -1` **strictly < the prior session's sum** · mapped tests green **0 skipped** · `grep -c "weak var vm\|viewModel: QuizViewModel" <NewFile>.swift` = 0 · every new file ≤ ~300 lines · temporary shims tagged `// TRANSITION-SHIM(#113)`.
4. **Commit/push/tick:** one commit per task; push to **`arch-review-ios` (NEVER main)**; tick the task in `issue-113-quizviewmodel-decomposition.md`, update the `docs/todo/TODO.md` #113 line, update this file's Status. Snapshot drift is expected pre-S7 — note it in the commit, don't chase it. Fail loud: no silent skips.

---

## Ready prompt — Session 1 (T1 EntitlementReconciler)

```
Work on issue #113 (Decompose QuizViewModel), Session 1 only: extract EntitlementReconciler (T1) — one commit. Behavior-preserving. Do NOT touch the other 4 clusters (later sessions). First: confirm #115 → #112 → #110 are merged (STOP if not), then re-derive anchors by grepping symbols and record the post-prereq sum-of-six `wc -l QuizViewModel*.swift | tail -1` into this file's Status as the shrink baseline.

Read first (already mapped — do NOT re-map):
- docs/issues/issue-113-execution-prompts.md → Recon snapshot + Locked decisions (1,2,4,5) + Standing gate.
- docs/issues/issue-113-quizviewmodel-decomposition.md → T1 + Acceptance "Per-extract" row + decisions 2/4.

Build: Move reconcileEntitlements / syncEntitlementsWithRetry / resyncBeforePaywallIfLocallyEntitled / refreshUsage / notifyPremiumPurchased + showPaywall/quotaLimitError/usageInfo state into ViewModels/EntitlementReconciler.swift (@MainActor ObservableObject the façade owns + re-publishes). Inject the entitlement/usage service + a transition(to:) write closure + a taskBag handle — NO vm back-pointer. Expose reset() (clears showPaywall/quotaLimitError) for T7. Touchpoint = +ScenePhase foreground-sync. If the +Recording 429 branch is still present, STOP (#112 didn't land). Port EntitlementReconcileTests; tag any temporary façade shim `// TRANSITION-SHIM(#113)`.

Done = EntitlementReconcileTests green (0 skipped); Standing-gate per-extract row holds (sum-of-six < recorded baseline; 0 back-pointers; EntitlementReconciler.swift ≤ ~300). Commit + push arch-review-ios; tick T1 + TODO + Status (record the baseline sum).
```

## Ready prompt — Session 2 (T2 AudioDeviceState)

```
Work on issue #113, Session 2 only: extract AudioDeviceState (T2) — one commit. Session 1 merged first. Behavior-preserving. Do NOT touch voice/timers/recording. Run the Standing gate (prereqs + T0 re-anchor; re-read the sum-of-six baseline from Status).

Read first: docs/issues/issue-113-execution-prompts.md → Recon + Locked (3,4) + Standing gate; issue-113-quizviewmodel-decomposition.md → T2 + Acceptance row.

Build: Move +Audio.swift's device slice (availableInputDevices/selectedInputDevice/currentIn+OutName computed, showingMicrophonePicker, setPreferredInputDevice/refreshAudioDevices, settings.audioMode+preferredInputDeviceId writes) AND the shared audio primitives (start/stopSilenceDetectionListening choke points) into ViewModels/AudioDeviceState.swift, so Voice/Recording later inject them. isPlayingQuestionTTS stays façade-resident — AudioDeviceState writes it via an injected closure (decision 4). Port AudioDevicePickerTests. +Audio.swift empties → delete it.

Done = AudioDevicePickerTests green (0 skipped); per-extract row holds (QuizViewModel+Audio.swift gone; sum shrinks; 0 back-pointers; AudioDeviceState.swift ≤ ~300). Commit + push arch-review-ios; tick T2 + TODO + Status.
```

## Ready prompt — Session 3 (T3 VoiceCommandCoordinator)

```
Work on issue #113, Session 3 only: extract VoiceCommandCoordinator (T3) — one commit. Sessions 1–2 merged. PURE MOVE — the dead .recording/.processing phases are deleted in S6a, NOT here. Run the Standing gate.

Read first: docs/issues/issue-113-execution-prompts.md → Recon + Locked (2,4) + Standing gate; issue-113-quizviewmodel-decomposition.md → T3 + Acceptance row.

Build: Move +CommandListener.swift (commandCapturePhase, lastRecognizedCommand, commandAvailability, pendingSkipWindow, voiceStart*Enabled, window/hint refresh, the routeCommand dispatch hub, onCommandRecognized/onSkipUndoWindowOpened) into ViewModels/VoiceCommandCoordinator.swift. routeCommand's fan-out targets reached via injected closures (transition, startNewQuiz, skip/undo, submitMCQ…), never a vm ref. MOVE Utilities/CommandCapturePhase.swift → ViewModels/CommandCapturePhase.swift (pins the file's final location for S6a/S7 greps). Expose reset() (clears commandCapturePhase/pendingSkipWindow) for T7. Port CommandListenerTests + SkipCancelWordTests (CommandCapturePhaseTests/StartCommandTests/ConfirmResultCommandTests/VoiceCommandObservabilityTests ride along). +CommandListener.swift empties → delete.

Done = CommandListenerTests + SkipCancelWordTests green (0 skipped); per-extract row holds (+CommandListener.swift gone; CommandCapturePhase.swift now under ViewModels/; sum shrinks; 0 back-pointers; VoiceCommandCoordinator.swift ≤ ~300). Commit + push arch-review-ios; tick T3 + TODO + Status.
```

## Ready prompt — Session 4 (T4 QuizTimersController)

```
Work on issue #113, Session 4 only: extract QuizTimersController (T4) — one commit. Sessions 1–3 merged. Run the Standing gate.

Read first: docs/issues/issue-113-execution-prompts.md → Recon + Locked (4,8) + Standing gate; issue-113-quizviewmodel-decomposition.md → T4 + Acceptance row.

Build: Move +Timers.swift (answerTimerCountdown, thinkingTimeCountdown, autoAdvanceCountdown, currentQuestionPaused, autoAdvanceEnabled, all countdown start/cancel) into ViewModels/QuizTimersController.swift. It writes isAutoRecording and calls startRecording/stopRecordingAndSubmit/confirmAnswer/proceedToNextQuestion — all injected closures; isAutoRecording/isRerecording stay façade-resident (decision 4). autoConfirmCountdown does NOT move — it stays façade-resident now (folds into ConfirmationState in S6b); QuizTimersController only drives its tick via an injected write closure. Do NOT delete autoAdvanceEnabled here (S6a does). Port QuizViewModelTimerTests AS-IS (it still exercises autoAdvanceEnabled = false — that axis dies in S6a). +Timers.swift empties → delete.

Done = QuizViewModelTimerTests green (0 skipped); per-extract row holds (+Timers.swift gone; sum shrinks; 0 back-pointers; QuizTimersController.swift ≤ ~300). Commit + push arch-review-ios; tick T4 + TODO + Status.
```

## Ready prompt — Session 5 (T5 RecordingCoordinator — heaviest, forced split)

```
Work on issue #113, Session 5 only: extract RecordingCoordinator (T5) — one commit. Sessions 1–4 merged. HEAVIEST/most entangled. Behavior-preserving. Run the Standing gate.

Read first: docs/issues/issue-113-execution-prompts.md → Recon + Locked (1,4,7,8) + Standing gate; issue-113-quizviewmodel-decomposition.md → T5 (the file-split spec) + Acceptance row.

Build: Move +Recording.swift's recording + confirmation clusters into an owned @MainActor ObservableObject. The 697-line body exceeds ≤300, so split into cohesive same-type files (repo +Extension convention): RecordingCoordinator.swift (~250: class + recording-cluster state + capture lifecycle + silence detection + commit watchdog + transcription-failure escalation + interruption/cleanup) · RecordingCoordinator+Submission.swift (~210: stopRecordingAndSubmit, submitVoiceAnswer, withUserFacingTimeout) · RecordingCoordinator+Confirmation.swift (~150: confirmAnswer, begin/cancelEditingTranscript, handleAnswerConfirmationDismissed, rerecordAnswer, cancelProcessing). Pressure valve: if RecordingCoordinator.swift still >300, split streaming-STT (startSTTEventListener + handleCommittedTranscript) into RecordingCoordinator+Streaming.swift (~120). Reads main-owned submissionEpoch + drives transition/setError/handleQuizResponse — all injected; isAutoRecording/isRerecording/isPlayingQuestionTTS façade-resident (decision 4). Recording+confirmation clusters land as PRIVATE fields on RecordingCoordinator (folded into RecordingState/ConfirmationState sub-structs in S6b — never on the façade); expose reset() for T7. Port QuizViewModelMCQVoiceTests + recording cluster (Streaming/Resubmit/SubmissionRace/AdvanceRace/ReplayContract/TTSSpy). +Recording.swift empties → delete.

Done = QuizViewModelMCQVoiceTests + recording cluster green (0 skipped); per-extract row holds (+Recording.swift gone; sum shrinks; 0 back-pointers across RecordingCoordinator*.swift; EVERY RecordingCoordinator*.swift ≤ ~300). Commit + push arch-review-ios; tick T5 + TODO + Status.
```

## Ready prompt — Session 6a (T6 dead-axis cleanups)

```
Work on issue #113, Session 6a only: two dead-axis deletions on now-relocated code (T6) — one commit. Sessions 1–5 merged. Behavior-changing but safe/isolated. Run the Standing gate.

Read first: docs/issues/issue-113-execution-prompts.md → Recon + Standing gate; issue-113-quizviewmodel-decomposition.md → T6 + the S6a per-session commit gate.

Build:
1) autoAdvanceEnabled (write-only-true, always true in prod): delete the property + its two resets; collapse the QuizTimersController guard to `!currentQuestionPaused`; delete the two ResultView reads (ResultView.swift — `if viewModel.autoAdvanceEnabled` and `guard viewModel.autoAdvanceEnabled`, grep them); remove the test reads (QuizViewModelTests + QuizViewModelTimerTests, plus the now-moot "no-op when autoAdvanceEnabled is false" timer test). GREP THE SYMBOL — the numbers are stale.
2) CommandCapturePhase dead phases: delete the unreachable .recording/.processing cases from ViewModels/CommandCapturePhase.swift (moved there in S3); update CommandCapturePhaseTests.

Done (S6a commit gate) = `grep -rn --include=*.swift "autoAdvanceEnabled" apps/ios-app/Hangs` = 0 (Swift-scoped so the deferred .stableDump .txt baselines don't false-fail) · `test -e ViewModels/CommandCapturePhase.swift && grep -cw "case recording\|case processing" ViewModels/CommandCapturePhase.swift` = 0 · QuizTimersController guard reads `!currentQuestionPaused` only · QuizViewModelTimerTests + CommandCapturePhaseTests green (0 skipped). Commit + push arch-review-ios; tick T6 + TODO + Status.
```

## Ready prompt — Session 6b (T7 unified reset model + resetState fix)

```
Work on issue #113, Session 6b only: unified phase-state reset model + resetState fix + computed score/questionsAnswered (T7) — one commit. Sessions 1–6a merged. Run the Standing gate.

Read first: docs/issues/issue-113-execution-prompts.md → Recon (esp. the computed-score fan-out incl. the QuizViewModel.swift:1440-1441 resetState deletion) + Locked (8) + Standing gate; issue-113-quizviewmodel-decomposition.md → T7 (the Field→mechanism table) + the S6b per-session commit gate.

Build:
- Uniform child reset(): each of the 5 children exposes reset() clearing its own scoped state. Façade resetState invokes ALL FIVE (full teardown); transition(to:) invokes a phase-owner child's reset() ONLY when LEAVING that owner's phase (decision 8) — never mid-quiz.
- Fold the recording+confirmation clusters into RecordingState/ConfirmationState PRIVATE @Published sub-structs INSIDE RecordingCoordinator (declared in QuizState+PhaseState.swift ≤ ~300), each with its own reset(); RecordingCoordinator.reset() resets both. autoConfirmCountdown resides in ConfirmationState; QuizTimersController drives its tick via the S4 injected closure now pointing at the ConfirmationState field.
- The two ownerless façade fields (activeErrorModel, mcqVoiceMatchedKey) get ONE explicit reset line each in resetState.
- Make score/questionsAnswered COMPUTED over currentSession (no stored backing). Add ONE shared helper Fixtures.session(score:answered:) and convert EVERY direct-assignment site to it — grep the assignment, don't trust the number (production/previews QuizViewModel+CompletionView; tests QuizViewModelTests/CompletionViewInspectorTests/ResultViewInspectorTests/Snapshots/ResultViewSnapshotTests). The resetState `score=0`/`questionsAnswered=0` pair (QuizViewModel.swift ~:1440-1441) become DELETIONS, not fixture migrations.
- Add an anti-drift test: a phase round-trip leaves ZERO residual across all ≥9 previously-missed fields, via the per-child reset() mechanism.

Done (S6b commit gate) = anti-drift test passes · score/questionsAnswered computed (no stored backing) and every fan-out site migrated to Fixtures.session (else behavior suite + previews won't compile) · all 5 children expose reset() invoked by resetState/transition; RecordingCoordinator resets its RecordingState/ConfirmationState; the two ownerless fields reset in resetState · QuizState+PhaseState.swift ≤ ~300 · full behavior suite green (0 skipped). Commit + push arch-review-ios; tick T7 + TODO + Status.
```

## Ready prompt — Session 7 (T8 snapshot re-record + final sweep — closing commit)

```
Work on issue #113, Session 7 only: snapshot re-record + final sweep (T8) — the CLOSING commit. Sessions 1–6b merged. Run the Standing gate.

Read first: docs/issues/issue-113-execution-prompts.md → Recon (snapshot gotcha) + Standing gate; issue-113-quizviewmodel-decomposition.md → T8 + the "Global" Acceptance list.

Build: Delete every façade forwarding shim tagged `// TRANSITION-SHIM(#113)`. Confirm all 5 extension files are gone and QuizViewModel.swift < ~300. Re-record the 4 .stableDump baselines ({Home,Question,Result,Paywall}) in ONE commit and verify the diff is model-restructure-only (fields moving into child storage), no view-render change (per ios.md "re-record signal, not hard block").

Done (Global acceptance, at this commit) = `find . -name "QuizViewModel+*.swift"` returns nothing · `wc -l QuizViewModel.swift` ≤ ~300 · full HangsTests green (0 skipped; re-run the 3 known async voice tests before declaring fail) · `grep -rn "weak var vm\|var viewModel: QuizViewModel" *Coordinator*.swift *Controller*.swift *State.swift *Reconciler*.swift` = 0 · `grep -rn "autoAdvanceEnabled" ../../` = 0 · `test -e CommandCapturePhase.swift && grep -cw "case recording\|case processing" CommandCapturePhase.swift` = 0 · anti-drift guard passes · score/questionsAnswered computed (no stored backing) · the 4 baselines re-recorded in EXACTLY ONE commit touching only Snapshots/* · `grep -rn "// TRANSITION-SHIM(#113)" .` = 0. Commit + push arch-review-ios; tick T8 + close the TODO #113 line + mark this file's Status complete.
```

---

## Status

- ✅ Recon + split done (this doc, 2026-07-20). Decisions 1–8 locked; 8 sessions (S1–S5, S6a, S6b, S7), strictly sequential. Prereq gate **satisfied 2026-07-20**: #115, #112, #110 (+#111) all landed on `arch-review-ios`.
- ✅ **S1 — T1 EntitlementReconciler** — DONE 2026-07-20, commit `59d318c`. **Sum-of-six baseline (post-prereq, recorded by S1): 2996. After S1: 2903** — S2 gates against 2903. Child = `ViewModels/EntitlementReconciler.swift` (209 lines, 0 back-pointers, `reset()` per T7 table). Gates: EntitlementReconcileTests 9/9 + PurchaseActivationTests + HomeFreePlanCardTests + CompletionView{Summary,Breakdown,Upsell}Tests green, 0 skipped; 3-lens adversarial verify passed. **Deviations vs this prompt (verified — no locked decision violated; do NOT "fix" back):** no `transition(to:)` closure (429 branch stays in façade `handleError` post-#112 — would be dead code) and no `taskBag` handle (the reconcile task must survive `resetState`'s `cancelAll`, as on HEAD — child deinit-cancels it). 0 TRANSITION-SHIM markers — every forward is a permanent decision-2 slice accessor with production callers. Expected `.stableDump` drift (S7 re-records): HomeView idleWithStats, QuestionView askingState+recordingState, ResultView correctVariant+incorrectVariant. ⚠ Gate-command note for later sessions: `CompletionViewInspectorTests` is a FILE with 3 suites (CompletionViewSummary/Breakdown/UpsellTests) — `-only-testing` silently no-ops on the file name; target the real suite names.
- ⬜ **S2 — T2 AudioDeviceState** — ready (S1 landed); gate sum < 2903.
- ⬜ **S3 — T3 VoiceCommandCoordinator (+ CommandCapturePhase file move)** — blocked on S2.
- ⬜ **S4 — T4 QuizTimersController** — blocked on S3.
- ⬜ **S5 — T5 RecordingCoordinator (forced internal split)** — blocked on S4; heaviest.
- ⬜ **S6a — T6 dead-axis cleanups** — blocked on S5.
- ⬜ **S6b — T7 unified reset model + resetState fix + computed score** — blocked on S6a.
- ⬜ **S7 — T8 snapshot re-record + final sweep** — blocked on S6b (closing commit).
