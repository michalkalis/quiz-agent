# Issue #59 — Quiz-flow bug cluster (8 voice-screen regressions)

**Triage:** bug · mostly done — remaining: RS sim legs + [HUMAN] device confirm

**Status (2026-07-06):** All 8 bugs + 7 loop tasks fixed 2026-06-17. Remaining: sim-geometry legs RS-12/RS-15 + click-through RS-11/13/16 via `/regression`, and [HUMAN] 59.1 real-device TTS confirm.
**Reversibility:** a · commits-only (no schema migration, no auth/payment, no prod deploy) — overnight-loop eligible
**Status:** Founder-reported 2026-06-17 from a live device session (Slovak, real AirPods). 8 bugs on the question + result screens. Root-caused + adversarially verified by a multi-agent workflow (`wf_59921dfa-ac4`, 17 agents). **No fixes applied yet — this is the evidence + plan.** Fixes are loop-able once founder picks the order.

## Why this issue exists (the meta-problem)

The founder's core complaint is not that bugs appear — it's that **they keep coming back after design/refactor changes**, and the automated safety net does not catch them.

Hard evidence:
- **All 10 RS regression scenarios (RS-01..RS-10) are GREEN as of 2026-06-17**, yet the app is visibly broken in real use.
- Several of these 8 bugs are **regressions of recently-shipped, already-"VISUAL: PASS"'d fixes**: the "Voice-answer screen 7-problem fix" (DONE 2026-06-13..15) reworked exactly this voice screen (incl. replay wiring, font, typed-answer fallback); #54 reworked end-quiz and recording. Those fixes were verified by **code-path inspection or mock-seeded screenshots**, not a real device run.

**Root diagnosis (why green ≠ working):** RS-01..RS-10 test only the *state machine* and *accessibility-tree presence*, never *behaviour correctness*. Every scenario runs `MockAudioService` + `MockNetworkService`, which replace the whole AVFoundation + URLSession stack with instant no-ops: TTS "plays" in 0.1 s and always succeeds, recording never touches an `AVAudioSession`, `endSession` always succeeds. Three bug classes are therefore **structurally invisible**: (a) real audio-session lifecycle (59.1, 59.3), (b) backend session lifecycle (59.4), (c) result-screen control correctness (59.7, 59.8). The rest (59.2 layout shift, 59.5 silent no-op, 59.6 missing spinner) are invisible because the suite asserts element *presence* but never element *geometry*, never "did playback actually fire", never UI state during the typed-answer gap.

The fix for the meta-problem is **Part B** below (new RS scenarios + structural guards). Closing the 8 bugs without Part B guarantees they regress again.

---

## Part A — The 8 bugs

Priority: **P0** = core hands-free value broken · **P1** = user stuck / wrong behaviour · **P2** = UX gap.
Each fix is the architecturally-correct change, not a patch. `file:line` from the verified root-cause.

### 59.1 — Question is not read aloud (TTS silent) · **P0** · confidence: medium (needs device confirm)
- **Symptom:** No question is spoken aloud — first or any.
- **Root cause:** `AudioService.withPlaybackCategory` (`Services/AudioService.swift:247-291`) switches the session to `.playback` via `setCategory(...)` at L262 but **never calls `setActive(true)` after the category change** (the correct pattern is in `setupAudioSession:195`). On iOS 26, after the mic engine has run, `AVPlayer` then stalls in `.waitingToPlayAtSpecifiedRate`; the 5 s stall timer (`AudioService.swift:796`) fires `AudioError.playbackFailed`, which `playQuestionAudio` (`QuizViewModel+Audio.swift:90`) **silently swallows** ("don't fail the quiz on audio"). Net: TTS never speaks, quiz continues normally → zero user signal.
- **Fix:** Add `try session.setActive(true)` after the `setCategory` at L262 **and** inside the `defer` restore block (the restore is currently name-only and can leave the session wired for `.playback`, which also harms recording).
- **Why it recurs:** Pure AVFoundation-lifecycle correctness, enforced by no type/test; doubly hidden (stall timer → swallow). Only manifests on real hardware.
- **RS gap:** `MockAudioService.playOpusAudio` sleeps 0.1 s and returns 3.0 unconditionally — the `withPlaybackCategory` path is never exercised. → **RS-11 + TTS-spy guard.**

### 59.2 — Answering countdown pushes content down (layout regression) · **P2** · confidence: high
- **Symptom:** When the answer/think countdown starts, a chip appears at the top and shoves the question + buttons downward.
- **Root cause:** `supportRow` (`Views/QuestionView.swift:134-150`) is a `@ViewBuilder` that goes from `EmptyView` → a real ~26 pt `HStack` the instant `answerTimerCountdown`/`thinkingTimeCountdown` becomes non-zero (set synchronously in `QuizViewModel+Timers.swift:37,84`). It sits inside `topChrome` (a `VStack` at the very top, `QuestionView.swift:81-94`), which reserves no space → everything below reflows.
- **Fix:** Take the chips out of the top chrome. Either a fixed-height row toggled with `.opacity`/`.hidden` (reserves the slot), or anchor the countdown to the bottom (over the action row) via overlay/ZStack so its appearance never reflows siblings. **Pencil** can confirm the intended bottom placement.
- **Why it recurs:** Conditional `@ViewBuilder` blocks in chrome VStacks are a standing SwiftUI trap; the same `errorBanner` in `topChrome` has the identical flaw. Each redesign that injects a new chrome row re-introduces reflow with no guardrail.
- **RS gap:** Suite asserts element presence/tappability, never y-geometry. → **RS-12 (frame-origin delta assert).** Related prior fix: 54.2 (same class, different element).

### 59.3 — Record button does not seem to record (AirPods) · **P0** · confidence: high
- **Symptom:** Tapping Record captures nothing with AirPods; other apps record fine with the same AirPods.
- **Root cause:** Default audio mode is **"media"** (`Models/AudioMode.swift` default = index 1). Its session options (`AudioService.swift:159-163`) include `.allowBluetoothA2DP` but **omit `.allowBluetoothHFP`**. A2DP is output-only — the AirPods mic is only reachable via HFP. So `AVAudioEngine.inputNode` gets the built-in mic or a 0 Hz format (guard at `:597` throws → silent fallback to batch recorder, also misrouted). Secondary: `withPlaybackCategory`'s `defer` can strand the session in `.playback` (no input) if the restore throws.
- **Fix:** Add `.allowBluetoothHFP` to the media-mode options. A2DP still wins for *output* when both flags are present, so the car "phone-call UI" is unaffected, but the Bluetooth **mic** becomes available. Add a `setupAudioSession(mode:)` recovery call in the `withPlaybackCategory` defer-catch.
- **Why it recurs:** The missing option *looks intentional* — the comment says "No HFP = no phone-call UI in car". The A2DP-is-output-only footgun is non-obvious and untested.
- **RS gap:** `MockAudioService.startStreamingRecording` just sets `isRecording = true`; no session/route ever exercised. → **RS-18 + categoryOptions read-back guard.**

### 59.4 — End quiz fails: "Session not found or already ended" · **P1** · confidence: high
- **Symptom:** Tapping X shows the red banner; user is stranded on the question screen.
- **Root cause:** `endQuiz()` (`QuizViewModel.swift:708-726`) calls `endSession` (`DELETE /sessions/{id}`); on a backend 404 it throws `NetworkError.sessionNotFound` ("Session not found or already ended", `NetworkService.swift:657-663`). The catch block **only sets `errorMessage`** — it does NOT clear session / reset state / stop audio, so the user stays put. The backend store is in-memory (`apps/quiz-agent/app/session/manager.py:37`) with a 30 min TTL + cleanup loop + lost-on-restart; the iOS `extendSession` is fire-and-forget `try?` (`QuizViewModel.swift:898`) so TTL drift is silent. Backend 404 is *correct* behaviour.
- **Fix:** Separate the two concerns. The invariant is "tapping X always returns Home." On `sessionNotFound` (session already gone) treat it as success → call the existing `resetToHome()` (clears session + resets state + stops audio). Only show the banner for errors that mean the session might still be live (e.g. timeout). Log the `extendSession` failure at warn level so the drift is diagnosable.
- **Why it recurs:** `endQuiz()` couples best-effort backend cleanup to the critical local UI reset in one try/catch. Every new "end quiz" affordance (e.g. #54 minimized widget) copies the pattern.
- **RS gap:** `MockNetworkService.endSession` never returns 404; no scenario taps X mid-quiz. → **RS-13 + injectable `endSessionError` guard.**

### 59.5 — Replay question does nothing · **P2** · confidence: high
- **Symptom:** Tapping "replay question" has no effect.
- **Root cause:** The button (`QuestionView.swift:285-300`) is always rendered/enabled and calls `replayQuestionAudio()` (`QuizViewModel+Audio.swift:115`), whose first line is `guard !settings.isMuted, let url = currentQuestionAudioUrl else { return }` — a **silent no-op**. `currentQuestionAudioUrl` is set only by `playQuestionAudio` (`:67`); when the backend returns a question with no `audio` field (`QuizViewModel.swift:447-455` else-branch), it stays `nil` for the question's whole life, so every tap no-ops on an interactive-looking button.
- **Fix:** Add `var canReplayAudio: Bool { !settings.isMuted && currentQuestionAudioUrl != nil }`; gate the button `.disabled(!canReplayAudio).opacity(...)`. View availability should track capability, not a hidden early-return.
- **Why it recurs:** Audio availability is a runtime (backend-dependent) property; the design tool always shows the button in its happy state, dev always has audio, the no-audio path only hits prod and is invisible in logs.
- **RS gap:** Mock always supplies `audio.questionUrl`, so replay never no-ops in tests; no scenario taps `question.replay`. → **RS-14 + disabled-state ViewInspector guard.**

### 59.6 — No processing indicator after submitting a typed answer · **P2** · confidence: high
- **Symptom:** After "Type answer instead" → send, the screen shows nothing happening until the result appears.
- **Root cause:** `submitTypedAnswer()` (`QuestionView.swift:440-446`) → `resubmitAnswer()` → state `.processing` (`QuizViewModel.swift:654`). `ContentView:52` maps `.processing` to the **same QuestionView**, but `voiceBody`'s pinned-controls block has **no `isProcessing` branch** (the `isProcessing` computed prop only dims the Skip button). The voice path shows a spinner only via `AnswerConfirmationView.processingBody` (`:206-238`) — which the typed path bypasses entirely.
- **Fix:** In the pinned-controls `VStack`, add `if isProcessing { processingRow } else { ... }` replacing the text-toggle + action row with a centered `ProgressView` + "Evaluating…" while the call is in flight (mirror `processingBody`). Don't open the voice sheet from the typed path.
- **Why it recurs:** Processing feedback lives only in the voice sheet, not in a shared place. `ContentView` collapses four states onto one view; any new entry into `.processing` inherits the gap.
- **RS gap:** No scenario exercises the typed-answer path, and mocks resolve instantly so the gap is unobservable. → **RS-15 + `question.processingIndicator` a11y-id guard.**

### 59.7 — Result read-aloud is wrong + auto-advance countdown starts too late · **P1** · confidence: high (Bug-A mechanism corrected on verify)
- **Symptom (as reported):** On the result screen, "read aloud" reads nothing and seems to start the next-question countdown; and that countdown should already be running when the result appears.
- **Root cause — Bug A (wrong function):** `ResultView.readAloudButton` (`ResultView.swift:96-111`) calls `viewModel.playQuestionAudio(from:)` — the **question-screen** flow function — instead of the timer-safe `replayQuestionAudio()` (`QuizViewModel+Audio.swift:115-132`). **Correction from adversarial verify:** `playQuestionAudio` does NOT actually start the countdown from the result screen (its `guard quizState == .askingQuestion` at `:98` returns early). The countdown the user sees was already started by `handleQuizResponse`. What `playQuestionAudio` *does* wrongly is call `stopSilenceDetectionListening()` and re-run question-screen teardown, and on a fresh `AVAudioEngine`/`AVPlayer` conflict the playback can silently drop → "reads nothing". The "starts the timer" impression is coincidental timing.
- **Root cause — Bug B (countdown too late):** `handleQuizResponse` (`QuizViewModel.swift:904-919`) runs feedback audio and `startAutoAdvanceCountdown` **sequentially in one Task** — the countdown only begins after feedback audio finishes (3–5 s of an invisible `countdownBar`).
- **Fix:** Bug A → call `replayQuestionAudio()` (drop the manual URL check; it reads the URL internally). Bug B → start the countdown from screen-appear (concurrent Task) using `settings.autoAdvanceDelay`; to avoid cutting feedback audio mid-sentence, base the duration on `max(autoAdvanceDelay, feedbackDuration)`.
- **Why it recurs:** Naming asymmetry — `playQuestionAudio` looks like the obvious "play question audio" call but carries hidden timer/teardown effects; the safe `replayQuestionAudio` reads as "re-listen". The sequential audio→countdown Task silently pushes the countdown later on any audio-timing refactor.
- **RS gap:** No scenario taps `result.readAloud`; mock audio has 0 duration so Bug B never surfaces. → **RS-16.** Related prior fix: the "Voice-answer screen 7-fix" introduced `replayQuestionAudio` but never updated the result screen to use it.

### 59.8 — "Resume auto-advance" immediately opens the next question · **P2** · confidence: high
- **Symptom:** Tapping "Resume auto-advance" jumps straight to the next question instead of resuming a countdown.
- **Root cause:** The button (`ResultView.swift:257-265`) calls `viewModel.continueToNext()` — the **same** action as the "Next question" button. `continueToNext()` (`QuizViewModel.swift:762-771`) clears the pause flag and immediately fires `proceedToNextQuestion()`. There is **no "resume countdown" method** in the ViewModel.
- **Fix:** Add `resumeAutoAdvance()` to QuizViewModel: set `currentQuestionPaused = false`, then `startAutoAdvanceCountdown(duration: settings.autoAdvanceDelay, audioDuration: 0)` (the existing guard at `+Timers.swift:149` already needs the flag cleared first). Wire the button to it; "Next question" keeps `continueToNext()`.
- **Why it recurs:** The correct action has no named method, so every redesign grabs the only visible one (`continueToNext`). It "does something", so the mistake isn't obvious without reading intent.
- **RS gap:** No pause→resume scenario; unit tests cover `pauseQuiz`/`startAutoAdvanceCountdown` in isolation but not the button action. → **RS-17 (the missing `resumeAutoAdvance()` is itself a compile-time signal).**

---

## Part B — Regression-prevention plan (so they don't come back)

This is the answer to "ako zaručiť, že sa bugy nevracajú pri zmenách dizajnu". The principle: **make each bug's correct behaviour assertable on the simulator without real audio/mic/backend** — via spy mocks, injectable errors, a11y-id contracts, and geometry asserts that survive design churn. Ties into #57 (loop verification backbone): these become part of the enforced gate so a `ralph/*` branch that reintroduces a bug fails before merge.

### B1. New RS scenarios (append to `docs/testing/regression-scenarios.md`, numbers never recycled)

| RS | Covers | Asserts (deterministic, no real audio) |
|----|--------|----------------------------------------|
| RS-11 | 59.1 | TTS-spy `mockAudio.playOpusCallCount >= 1` after `askingQuestion`; with `shouldFailPlayback`, quiz still reaches `recording` AND TTS re-attempted next question |
| RS-12 | 59.2 | `snapshot_ui` frame.origin.y of `question.record` before vs. after `answerTimerCountdown > 0`; delta < 4 pt |
| RS-13 | 59.4 | Unit: `endSession` throws `sessionNotFound` → `quizState == .idle`, `currentSession == nil`, `errorMessage == nil`. Sim: tap X mid-quiz → HomeView (`home.startQuiz` visible, no banner) |
| RS-14 | 59.5 | ViewInspector: `currentQuestionAudioUrl == nil` → `question.replay` disabled/absent; non-nil → enabled |
| RS-15 | 59.6 | After typed submit, `snapshot_ui` within ~200 ms shows `question.processingIndicator` before state reaches `showingResult` |
| RS-16 | 59.7 | Unit: `replayQuestionAudio()` → `playOpusCallCount == 1` AND `autoAdvanceCountdown` unchanged; `playQuestionAudio` documented to re-arm (contract diff). Sim: tap `result.readAloud` → still `showingResult`, countdown value preserved |
| RS-17 | 59.8 | Unit: `pauseQuiz()` then `resumeAutoAdvance()` → `quizState == .showingResult` (not `askingQuestion`) and `autoAdvanceCountdown > 0`. Sim: Stay-here → resume → still on result screen |
| RS-18 | 59.3 | AudioService unit (real instance, sim, no hardware): `setupAudioSession(mode:.media)` then assert `AVAudioSession.categoryOptions` contains `.allowBluetoothHFP` |

### B2. Structural guards (seams that make the invariants testable without hardware)

1. **TTS spy** — add `playOpusCallCount: Int` + `lastPlayedData: Data?` to `MockAudioService`; every `playOpusAudio` increments. Converts "TTS was attempted" into a deterministic value that survives any audio-infra redesign (the protocol forces every mock to implement it). *(59.1, 59.7)*
2. **Injectable `endSessionError`** on `MockNetworkService` (parallel to `createSessionError`) + `endSessionCallCount` — lets one test exercise the 404-only path without breaking every other call. *(59.4)*
3. **`resumeAutoAdvance()` as a first-class VM method** — eliminates the "invisible correct choice" that makes copy-pasting `continueToNext()` the default. *(59.8)*
4. **`question.processingIndicator` a11y-id contract** in the typed-answer processing branch — presence is compile-testable via ViewInspector, independent of visual design. *(59.6)*
5. **Replay disabled-state ViewInspector test** — a button with no effect must not look interactive; pins the capability→availability invariant. *(59.5)*
6. **`categoryOptions` read-back AudioService test** — fails the instant anyone strips `.allowBluetoothHFP`; the test body documents *why* HFP must stay (mic access, not just UI). *(59.3)*

### B3. Process change (the real root of "green but broken")

- **Layout/geometry guard:** the RS suite must add at least one frame-origin assertion per screen (RS-12 is the template) so conditional chrome rows can't silently reflow pinned controls. This is allowed under the #57 "gate on flow/state/element-presence" rule — it asserts *layout stability*, not pixel/`.pen` fidelity.
- **No more "code-path inspection" as a verification of an audio/recording/session change.** Those three classes are exactly the mock blind spots; they require either a real-device pass or the spy/read-back guards above. Record the verification method in the run report, not just VERDICT: PASS.

---

## Sequencing (loop-able)

Suggested order once founder approves (P0 first; each is independently committable + has its RS guard land with it per #57):
1. **59.3** (recording) + **59.1** (TTS) — P0, both in `AudioService`; land RS-18 + RS-11 + TTS-spy with them. *Needs one real-device confirm for 59.1 (medium confidence).*
2. **59.4** (end quiz) + **59.7** (result read-aloud/countdown) — P1; land RS-13/RS-16.
3. **59.2 / 59.5 / 59.6 / 59.8** — P2 UX; land RS-12/RS-14/RS-15/RS-17 + guards.

A `/goal` or Ralph loop can run per-bug with the matching RS scenario as the machine-checkable acceptance. Do NOT mark a bug done off a green mock suite alone — the new guard for that bug must be the thing that goes red→green.

---

## Tasks (atomic — Ralph self-selects in order; one fix + its guard + its RS scenario per task)

Founder approved the full-set, priority-ordered run 2026-06-17. Each task is independently committable; the new RS guard for that bug must land in the same commit and is the thing that goes red→green (per #57).

**P0 — both in `AudioService`:**
- [x] **59.3** — Added `.allowBluetoothHFP` to media-mode session options; added a `setupAudioSession(mode:)` recovery in the `withPlaybackCategory` defer-catch. Landed **RS-18** — but **reworked**: the option logic was extracted into a pure `nonisolated static AudioService.categoryOptions(for:)` and the test reads that back, instead of instantiating a live `AudioService` + `setActive` (the suspected HangsTests-hang path, per handoff 2026-06-17-1555). RS-18 spec in `regression-scenarios.md` updated to match. *(green on iPhone 17 Pro sim)*
- [x] **59.1** — Added `try session.setActive(true)` after the `.playback` `setCategory` **and** in the defer-restore block (plus session-recovery in the catch, shared with 59.3). Added `playOpusCallCount: Int` + `lastPlayedData: Data?` TTS-spy to `MockAudioService`. Landed **RS-11** (`QuizViewModelTTSSpyTests` + mock spy-contract tests). *(green on sim; real-device confirm still pending — see `[HUMAN]` below)*
- [HUMAN] **59.1-device-confirm** — OUT OF LOOP. Confirm on a real iOS 26 device (Slovak, AirPods) that the question is actually spoken aloud. Root cause is medium-confidence and the symptom is not observable on the simulator (mock TTS always "succeeds"). Do **not** mark 59.1 fully done off a green sim suite.

**P1:**
- [x] **59.4** — Split end-quiz concerns in `endQuiz()`: `catch NetworkError.sessionNotFound` → `resetToHome()` (already-gone session = success, no banner); generic `catch` keeps the banner for errors meaning the session may still be live (no reset, user can retry); `extendSession` is now a warn-logged `do/catch` (was silent `try?`). Added `endSessionError: Error?` + `endSessionCallCount: Int` to `MockNetworkService`. Landed **RS-13** as two `@Test`s in the existing `QuizViewModel End Quiz Tests` suite (sessionNotFound→Home+no-banner; live-error→banner+no-reset). *(both green on iPhone 17 Pro sim; sim-driven leg of RS-13 runs via `/regression`)*
- [x] **59.7** — **Bug A:** `ResultView.readAloudButton` now calls `replayQuestionAudio()` (timer-safe, reads URL internally) instead of `playQuestionAudio(from:)` (the question-screen flow fn that tears down silence detection + re-arms timers and can silently drop playback). **Bug B:** `handleQuizResponse` now starts the auto-advance countdown *immediately* (concurrent `async let` for feedback audio) so the countdown bar is visible the instant the result appears — was sequential (audio → then countdown), leaving the bar invisible for 3-5s. *Note:* the spec's `max(autoAdvanceDelay, feedbackDuration)` isn't applied literally — feedbackDuration is only known after playback, and the default delay (8s) exceeds typical feedback length, so audio isn't cut; countdown starts at `autoAdvanceDelay`. Landed **RS-16** (`QuizViewModelReplayContractTests`: replay plays once + countdown preserved; no-op when muted / no URL). *(3 green on iPhone 17 Pro sim; sim leg via `/regression`)*

**P2 — UX:**
- [x] **59.2** — `supportRow` now reserves a fixed-height slot (`supportRowHeight = 30`) for the *whole* `askingQuestion` phase (chips conditionally rendered inside a constant-height frame) instead of toggling `EmptyView → real row` the instant the countdown becomes non-zero. The chips fade in with zero layout shift; the slot collapses once we leave `askingQuestion`. RS-12 (frame-origin delta) is the sim/`snapshot_ui` leg — runs via `/regression`. *Chose reserve-the-slot over bottom-overlay per Rule #1 (minimal); founder may prefer the overlay on visual review.*
- [x] **59.5** — Added `var canReplayAudio: Bool { !settings.isMuted && currentQuestionAudioUrl != nil }` to the VM; gated `question.replay` with `.disabled(!canReplayAudio)` + dimmed opacity. Landed **RS-14** (2 ViewInspector tests: disabled when no URL, enabled when URL present).
- [x] **59.6** — Added `if isProcessing { processingRow } else { … }` to the `voiceBody` pinned-controls `VStack`; `processingRow` is a centered `ProgressView` + "Evaluating…" with a11y-id `question.processingIndicator` (mirrors the voice sheet's `processingBody`, which the typed path bypasses). Landed **RS-15** (2 ViewInspector tests: present in `.processing`, absent in `.askingQuestion`).
- [x] **59.8** — Added `resumeAutoAdvance()` to `QuizViewModel` (clears `currentQuestionPaused`, re-arms `startAutoAdvanceCountdown`); wired the "Resume auto-advance" button to it. "Next question" keeps `continueToNext()`. Landed **RS-17** (unit: pause → resume → still `showingResult` + `autoAdvanceCountdown > 0`).

## Acceptance

Loop-evaluable on the simulator (the `[HUMAN]` line is out-of-loop and must NOT gate the run):

- [x] All 7 `- [ ]` tasks above are committed, and each bug's fix + its RS guard landed in the same commit (P0 59.3/59.1 → `4eb149d`; 59.4 → `c7d5f3d`; 59.7 → `8ecba58`; P2 59.2/59.5/59.6/59.8 → this commit).
- [x] iOS unit suite green: `xcodebuild test -only-testing:HangsTests` (scheme `Hangs-Local`, config `Debug-Local`). New tests for RS-11/13/14/16/17/18 exist and pass; RS-01..RS-10 still green. *Only the 5 pre-existing `*SnapshotTests` suites are red — caused by the founder's uncommitted `Localizable.xcstrings` localization WIP, not #59; they are non-gating `.stableDump` re-record signals per the Verification Altitude rule (#57).*
- [x] Structural seams exist and compile (they are themselves the guards): `MockAudioService.playOpusCallCount`/`lastPlayedData`; `MockNetworkService.endSessionError`/`endSessionCallCount`; `QuizViewModel.resumeAutoAdvance()` and `canReplayAudio`; a11y-id `question.processingIndicator` in the typed-answer processing branch.
- [ ] RS-11..RS-18 are appended to `docs/testing/regression-scenarios.md` ✅; **but the sim-driven legs (RS-11/12/13/15/16/17) have NOT been run via the `/regression` skill this session** (unit/ViewInspector guards landed; the on-sim click-through + `snapshot_ui` geometry legs for RS-12/RS-15 still need a `/regression` pass with per-run reports in `docs/testing/runs/`).
- [HUMAN] 59.1 real-device confirm (see task above) — the closing check that TTS actually speaks on iOS 26 hardware. Out of loop; founder verifies in the morning.

---

*Generated from workflow `wf_59921dfa-ac4` (root-cause → adversarial verify → prevention synthesis). Full per-bug verifier notes available in the run transcript.*

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-54-design-refresh-regressions|#54 Design-refresh sweep regressions]] · [[issue-57-loop-verification-backbone|#57 Autonomous loop hardening]]
<!-- obsidian-links:end -->
