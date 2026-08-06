# Issue 149: Mic arming has two paths and only one honours the command window

**Triage:** bug · needs-triage
**Priority:** serious
**Source:** architectural audit 2026-08-06
**Reversibility:** a
**Created:** 2026-08-06

## Context

The voice-command window (`currentCommandScreen`) is documented as the single source of truth for when the mic may be armed and which commands are in scope. In practice only one of the two arming paths asks it: the playback tails (`AudioDeviceState+Playback`) call the low-level choke point directly, and that choke point re-validates just foreground + not-playing-TTS. The user-visible consequence is that the Settings "Voice commands" toggle behaves as a routing filter rather than a capture switch — flipping it off tears the listener down once, and the next question's TTS tail silently re-arms the microphone for the rest of the session. The same asymmetry lets a TTS tail that resumes after the quiz has already finished start the audio engine after the audio session was deactivated. For a hands-free driving app, "mic is live when the user turned voice commands off" is a trust problem, not just a leak.

## Confirmed findings

**F1 — `startSilenceDetectionListening()` never consults the command window.**
`apps/ios-app/Hangs/Hangs/ViewModels/AudioDeviceState.swift:160-210`. The function guards only `guard isAppForeground()` (:167) and, after the suspension, `guard isAppForeground(), !isPlayingAnyTTS()` (:189); it then unconditionally arms barge-in (`service.makeBargeInStream()`, :198) and the command consumer (`startCommandConsumer()`, :209). It never reads `currentCommandScreen`, which `VoiceCommandCoordinator+Listening.swift:22-50` documents as *"the single source of truth for both arming and for scoping the matcher"* and which additionally gates on `settings().voiceCommandsEnabled` (:30), `isAppForeground()` (:35), `isPlayingTTS() || isRecordingActive` (:41) and the quiz-state map (:43-49).

**F2 — five call sites bypass the window predicate.**
`AudioDeviceState+Playback.swift:23` (mute path), `:51` (every question's TTS tail), `:126` (replay tail), `:178` (feedback tail, inside `withCommandWindowClosed`), and `QuizViewModel.swift:961` (quiz start, no-audio path). Only `VoiceCommandCoordinator+Listening.swift:78` reaches it through the window-aware sync path. The service layer offers no backstop: `SilenceDetectionService.startListening()` (`Services/SilenceDetectionService+Engine.swift:28-48`) carries only the #133 single-flight guard — no settings or window gate.

**F3 — the Settings master switch does not stay off.**
`SettingsView.swift:211` calls `refreshCommandWindow()` when the toggle flips, which tears the listener down exactly once. The very next `playQuestionAudio` tail (`Playback.swift:50-51`) re-arms the SpeechAnalyzer input tap and the command consumer regardless. Qualifier: with the toggle off the consumer is functionally inert — `handleCommandTranscript` drops on `guard let screen = currentCommandScreen` (`VoiceCommandCoordinator+Routing.swift:70`) — so commands do not misfire. What leaks is live microphone capture and a running audio engine, not wrong command behaviour.

**F4 — the finished-quiz tail re-arms after `deactivateSession()`.**
`endQuizWithResults()` (`QuizViewModel.swift:1470-1490`) runs `taskBag.cancelAll()` → `stopSilenceDetectionListening()` → `stopAnyPlayingAudio()` → `deactivateSession()`. But `playQuestionAudio`'s tail has no `Task.isCancelled` or quiz-state check before re-arming — exactly the guard `replayQuestionAudio` *does* have (`Playback.swift:118-121`). The tail resumes and starts the engine in `.finished`/`.idle` after the session was torn down.

**F5 — barge-in is not governed by the same policy (constraint, not a defect).**
The same choke point arms barge-in (`AudioDeviceState.swift:198`), which must keep working while `currentCommandScreen` is nil — barge-in is not gated by `voiceCommandsEnabled` (that setting was removed). A naive "bail when the command window is nil" fix would silently kill barge-in. This is the design constraint the fix must respect, and it is why the audit's own one-line fix sketch is rejected below.

**Not a duplicate:** `docs/issues/INDEX.md` has nothing on this seam (#121 is HUD flicker, #124 is Home volume, #100.4 / #133-1c are engine re-entrancy). No existing test covers a playback tail re-arming after the toggle is flipped off — `QuietListeningWindowTests` and `VoiceCommandObservabilityTests` only exercise the sync path.

*(No findings in this issue are unverified; all five were confirmed against the code on 2026-08-06.)*

## Proposed approach

One choke-point refactor, no behaviour spread across call sites.

1. **Split the policy in two, deliberately.** Introduce a *capture* predicate (may the audio engine / input tap be live at all: foreground, no TTS, no active recording, quiz not finished/torn down) distinct from the existing *command-window* predicate (`currentCommandScreen`: capture predicate **plus** `voiceCommandsEnabled` plus the screen map). Capture governs the engine and barge-in; the command window governs only whether the command consumer is armed and how the matcher is scoped.
2. **Make `startSilenceDetectionListening()` the single enforcement point.** It consults the capture predicate before arming anything and bails if it is false, and consults the command-window predicate before `startCommandConsumer()`. The predicate is injected (same closure style as the existing `AudioDeviceState` dependencies) so `AudioDeviceState` does not gain a hard dependency on `VoiceCommandCoordinator`.
3. **Keep the post-suspension re-validation.** The existing re-check after `await service.startListening()` stays and must evaluate the *same* predicate, since a teardown can land inside that suspension window (the #133 / #100.4 hazard).
4. **Include quiz teardown in the capture predicate** so F4 is fixed structurally rather than by copying `replayQuestionAudio`'s ad-hoc `Task.isCancelled` guard into three more tails.
5. **Delete the reimplemented halves.** The five call sites keep calling the choke point and stop carrying their own partial conditions; any that then hold no unique logic collapse to a plain call.
6. **Add a service-level backstop only if it is free** — if a cheap assertion in `SilenceDetectionService.startListening()` can catch a future bypass without duplicating policy, add it; otherwise skip rather than fork the predicate.

Rejected: reusing `currentCommandScreen` verbatim as the arming gate (kills barge-in, F5). Rejected: patching each tail with its own guard (that is the defect, restated).

## Done criteria

- [x] Exactly one place in the codebase decides whether the mic may be armed; grep for `startListening`/`startCommandConsumer` shows no call site carrying its own foreground/TTS/state conditions. — `AudioDeviceState.startSilenceDetectionListening()` is the only gate; the five call sites are now plain calls (`withCommandWindowClosed`'s `if !isPlayingQuestionTTS()` deleted). `syncCommandListenerWindow` still reads `currentCommandScreen`, but to pick the quiet session and to decide start-vs-stop — it restates no condition.
- [x] Unit test: with `voiceCommandsEnabled = false`, driving a full question TTS cycle (mute path and audio path) leaves the silence-detection service **not** listening and the command consumer not armed — fails on today's code. — `MicArmingPredicateTests`, audio + mute + feedback tails; verified failing against the pre-change predicate.
- [x] Unit test: barge-in still arms and fires — proves the fix did not close the window on barge-in (F5). **Deviation:** tested with `voiceCommandsEnabled = true`, not false. The criterion as written contradicts the two above and the manual leg: the toggle is implemented as a *capture* switch (which is what "the orange mic indicator stays off for the rest of the session" requires), so with it off nothing captures, barge-in included. Barge-in is instead proven independent of the *screen map*, which is what the naive `currentCommandScreen != nil` fix would have broken.
- [x] Unit test: a question-TTS tail resuming after `endQuizWithResults()` does not start the engine (state is `.finished`, session deactivated) — covers F4.
- [x] Existing `QuietListeningWindowTests` and `VoiceCommandObservabilityTests` stay green; no snapshot re-record required (no UI change). — plus 9 further voice/TTS suites: 91 tests / 11 suites green.
- [ ] Manual simulator leg: start a quiz, flip Settings "Voice commands" off mid-quiz, continue two questions — the iOS orange mic indicator stays off for the rest of the session. — **open (founder leg).**
- [x] Files touched limited to `AudioDeviceState.swift`, `AudioDeviceState+Playback.swift`, `SilenceDetectionService*`, `VoiceCommandCoordinator+Listening.swift` (+ tests); `QuizViewModel.swift:961` adjusted only if it still needs its own call. — `SilenceDetectionService*` untouched (the service-level backstop would have forked the predicate, so it was skipped per approach step 6); `QuizViewModel.swift` touched only to inject the two predicate closures, and `:961` needed no change.

**Consequence to note:** with "Voice commands" off, barge-in (speak to interrupt the question read) is off too — it shares the microphone the toggle now switches. The auto-record countdown still starts the recording, so the answer flow is unaffected.
