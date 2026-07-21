# Regression Scenarios — Hangs iOS

Autonomous test scenarios run by Claude via XcodeBuildMCP after iOS code
changes. Focus is **state machine + screen flow correctness**, not STT/TTS
quality. See `docs/issues/issue-16-autonomous-ui-testing.md` for setup.

## How a scenario is executed

Preconditions are set up by launching the app with `--ui-test` (see
`UITestSupport.swift`). The app boots with mock services pre-populated by
`QuizResponse.previewStartQuiz`, no real backend, no real audio.

Steps drive UI via XcodeBuildMCP accessibility-tree taps and a tiny
DEBUG-only HTTP listener on `127.0.0.1:9999` (see
`UITestSupport.startTestListener()`) for STT events. The legacy
`hangs-test://` URL scheme handler is still wired and may work on real
devices, but iOS 26.3 simulator drops it (LaunchServices bug), so the
HTTP path is canonical.

| Curl | Effect |
|---|---|
| `curl -s "http://127.0.0.1:9999/stt/connected"`           | injects `STTEvent.connected` |
| `curl -s "http://127.0.0.1:9999/stt/partial?text=foo"`    | injects `STTEvent.partialTranscript("foo")` |
| `curl -s "http://127.0.0.1:9999/stt/committed?text=foo"`  | injects `STTEvent.committedTranscript("foo")` |
| `curl -s "http://127.0.0.1:9999/stt/disconnect?msg=..."`  | injects `STTEvent.disconnected(error)` |

State assertions read the label of the hidden static text element
`question.state` (values: `idle`, `startingQuiz`, `askingQuestion`,
`recording`, `processing`, `showingResult`, `finished`, `error`) and
the presence of `confirmation.state.{processing,transcript}`
identifiers on the sheet.

Crash detection: stream simulator log via XcodeBuildMCP, fail scenario
on any `EXC_*` signal or app-process exit.

Numbering: `RS-N` (Regression Scenario). Numbers are never recycled —
when a scenario is removed, its number is retired.

**Sibling XCUITest RS family (not in this registry):**
`HangsUITests/Regression/RegressionTests.swift` carries the XCUITest-embodied
scenarios (`testRSStart` / `testRSCorrect` / `testRSIncorrect` /
`testRSLongQuestion` / `testRSPaywall` / `testRSPackNavStart` — the #111
pack-nav voice-start teardown), run via
`xcodebuild test -scheme Hangs-Local -only-testing:HangsUITests/RegressionTests`,
not via the MCP-driven steps below. Check both families before concluding a
flow is uncovered.

---

## RS-01: Recording stops on committed transcript

**Hypothesis:** After ElevenLabs commits the final transcript, the app
must leave `recording` state, surface the confirmation sheet, and not
crash.

**Preconditions**
- Launch with `--ui-test`
- App on `HomeView`

**Steps**
1. Tap `home.startQuiz`
2. Wait for `question.state` label to become `askingQuestion`
3. Tap `question.micButton`
4. Wait for `question.state` label to become `recording`
5. `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null`
6. Wait up to 3s

**Asserts**
- `question.state` label is `processing` OR confirmation sheet is visible
- `confirmation.state.transcript` exists (not `confirmation.state.processing` after sheet stabilizes)
- `confirmation.answer` text contains `Paris`
- App process is alive; no `EXC_*` in log
- `question.errorBanner` is **not** present

---

## RS-02: Hard auto-stop fires when no STT events arrive

**Hypothesis:** When no committed transcript ever lands, the 15s safety
timer (`Config.autoRecordingDuration`) must stop recording and route to
a recoverable state.

**Preconditions**
- Launch with `--ui-test`

**Steps**
1. Tap `home.startQuiz`
2. Tap `question.micButton`
3. Wait for `question.state` label `recording`
4. **Do not** inject any STT events
5. Wait 18s

**Asserts**
- `question.state` label is **not** `recording` (one of: `processing`, `askingQuestion`, `error`)
- App process is alive; no `EXC_*` in log
- If `error`, `question.errorBanner` text is human-readable (not empty, not "Optional(...)")

---

## RS-03: Stale error from a failed attempt does not bleed into the next recording

**Hypothesis:** If a previous recording produced an error, starting a new
recording must clear it.

**Preconditions**
- Launch with `--ui-test`
- Pre-existing error on screen: trigger via
  `curl -s "http://127.0.0.1:9999/stt/disconnect?msg=fake-error"` mid-recording

**Steps**
1. Tap `home.startQuiz`
2. Tap `question.micButton`; wait for `recording`
3. `curl -s "http://127.0.0.1:9999/stt/disconnect?msg=upstream-down" >/dev/null`
4. Wait until `question.errorBanner` is visible
5. Tap `question.micButton` again to start a fresh recording
6. Wait for `question.state` label `recording`

**Asserts**
- `question.errorBanner` is **not** present after step 6
- App process is alive

---

## RS-04: Rapid double-tap on the mic does not crash and lands in a legal state

**Hypothesis:** Reentrant taps must not violate `validTransitions` or
crash. The double-stop guard (`isStoppingRecording`) should hold.

**Preconditions**
- Launch with `--ui-test`

**Steps**
1. Tap `home.startQuiz`
2. Tap `question.micButton` twice within 200ms

**Asserts**
- `question.state` label is one of `askingQuestion`, `recording`, `processing` after settle (≤2s)
- App process is alive; no `EXC_*` in log

---

## RS-05: Cancel from confirmation sheet returns to askingQuestion (not stuck in processing)

**Hypothesis:** Cancelling from the confirmation sheet must reset state
to `askingQuestion` so the user can re-record. No orphaned
`processing` state.

**Preconditions**
- Launch with `--ui-test`

**Steps**
1. Tap `home.startQuiz`
2. Tap `question.micButton`; wait for `recording`
3. `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null`
4. Wait for confirmation sheet (`confirmation.state.transcript` or `.processing`)
5. If sheet is in processing branch, wait until it switches to transcript branch (or timeout 3s)
6. Tap `confirmation.cancel` if present, otherwise dismiss with `confirmation.reRecord`

**Asserts**
- After dismissal, `question.state` label is `askingQuestion`
- No confirmation sheet visible
- App process is alive

---

## RS-06: Edit transcribed answer and confirm

**Hypothesis:** Tapping the pencil edit affordance, typing a replacement
answer, and tapping Confirm must transition the state machine into
`showingResult` without surfacing an error banner.

**Preconditions**
- Launch with `--ui-test`
- bug-A from issue-19 must be fixed (`MockNetworkService.submitTextInput`
  returns a response with an evaluation) — otherwise this scenario fails
  at step 7 with "Could not evaluate your answer". Author the scenario now;
  expect FAIL until bug-A lands. See `docs/issues/issue-19-auto-confirm-resubmit-bug.md`.

**Steps**
1. Tap `home.startQuiz`; wait for `question.state` label `askingQuestion`
2. Tap `question.micButton`; wait for `recording`
3. `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null`
4. Wait for `confirmation.state.transcript` to be visible
5. Tap `confirmation.edit` (pencil button)
6. Type `Lyon` into `confirmation.answerField` (replaces transcript)
7. Tap `confirmation.confirm`
8. Wait up to 5s for state change

**Asserts**
- `question.state` label is `showingResult`
- `question.errorBanner` is **not** present
- App process is alive; no `EXC_*` in log
- Log shows `transcriptWasEdited = true` path was taken (TTS suppressed)

---

## RS-07: Edit then re-record dismisses the sheet without submitting

**Hypothesis:** Entering edit mode and then tapping Re-record must discard
the in-progress edit, return state to `askingQuestion`, and never call
`resubmitAnswer` (no network submission, no evaluation error). The
auto-confirm timer must stay cancelled (it was cancelled by `beginEditingTranscript`
on edit-tap and must not restart).

**Preconditions**
- Launch with `--ui-test`
- Independent of bug-A (no `submitTextInput` call on this path)

**Steps**
1. Tap `home.startQuiz`; wait for `askingQuestion`
2. Tap `question.micButton`; wait for `recording`
3. `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null`
4. Wait for `confirmation.state.transcript`
5. Tap `confirmation.edit`
6. Type `Berlin` into `confirmation.answerField`
7. Tap `confirmation.reRecord`
8. Wait up to 3s

**Asserts**
- `question.state` label is `askingQuestion`
- No confirmation sheet visible (`confirmation.state.transcript` and
  `confirmation.state.processing` both absent)
- `question.errorBanner` is **not** present
- Log does **not** contain `✏️ Resubmitting edited answer`
- App process is alive; no `EXC_*` in log

---

## RS-08: Cancel from edit field returns to read-only transcript

**Hypothesis:** Tapping a cancel control while editing must (a) exit edit
mode, (b) restore `confirmation.answer` to the original committed transcript
(discarding the in-progress edit), and (c) leave the sheet up — *not*
dismiss to `askingQuestion`. Cancel-from-edit is a localized "undo this
edit", not a global "abandon this answer".

**Preconditions**
- Launch with `--ui-test`
- `confirmation.editCancel` button is present in the edit branch and is
  wired to `cancelEditingTranscript()` which restores `transcribedAnswer`
  from a snapshot taken at edit-begin

**Steps**
1. Tap `home.startQuiz`; wait for `askingQuestion`
2. Tap `question.micButton`; wait for `recording`
3. `curl -s "http://127.0.0.1:9999/stt/committed?text=Paris" >/dev/null`
4. Wait for `confirmation.state.transcript`
5. Tap `confirmation.edit`; type `Berlin` into `confirmation.answerField`
6. Tap `confirmation.editCancel`
7. Wait up to 2s

**Asserts**
- `confirmation.state.transcript` is still visible (sheet did **not** dismiss)
- `confirmation.answer` text contains `Paris` (original) and **not** `Berlin`
- `confirmation.answerField` is **not** present
- `question.state` label is **not** `askingQuestion` (still `processing`)
- `question.errorBanner` is **not** present
- App process is alive

---

## RS-09: MCQ voice answer highlights option and submits

**Hypothesis:** When the app receives a committed transcript that matches an MCQ option,
`MCQTranscriptMatcher` maps it to the correct key, `mcqVoiceMatchedKey` is set so the matching
`AnswerOption` highlights as `selected`, and `submitTextInput` is called transitioning to
`processing`. The voice path is now functional for multiple-choice questions (issue #45, 45.3/45.9).

**Preconditions**
- Launch with `--ui-test --ui-test-mcq`
- `Question.previewMCQ` is loaded: "What is the largest planet?" options a=Mars b=Jupiter c=Saturn d=Neptune
- `answerTimeLimit = 1` (seeded by UITestSupport for `--ui-test-mcq`): recording auto-starts ~1-2s
  after question audio (no mic button in the redesigned UI)

**Steps**
1. Tap `home.startQuiz`
2. Wait for `question.state` label `askingQuestion` (up to 5s)
3. Confirm `mcq.option.a` is present in the accessibility tree (MCQ screen rendered)
4. Wait for `question.state` label `recording` (up to 5s — answer timer fires after ~1s, then STT connect)
5. `curl -s "http://127.0.0.1:9999/stt/committed?text=Jupiter" >/dev/null`
6. Wait up to 3s

**Asserts**
- `question.state` label is `processing`
- `mcq.option.b` is present in the accessibility tree (MCQ options still rendered)
- App process is alive; no `EXC_*` in log
- `question.errorBanner` is **not** present

---

## RS-10: MCQ tap answer submits and transitions to processing

**Hypothesis:** Tapping an MCQ option calls `submitMCQAnswer` after the 500ms confirm delay
and the ViewModel transitions to `processing`. This covers the tap-to-answer path that complements
the voice path tested in RS-09.

**Preconditions**
- Launch with `--ui-test --ui-test-mcq`
- `Question.previewMCQ` is loaded: options a=Mars b=Jupiter c=Saturn d=Neptune

**Steps**
1. Tap `home.startQuiz`
2. Wait for `question.state` label `askingQuestion` (up to 5s)
3. Confirm `mcq.option.b` is present in the accessibility tree
4. Tap `mcq.option.b` (Jupiter)
5. Wait up to 2s

**Asserts**
- `question.state` label is `processing`
- App process is alive; no `EXC_*` in log
- `question.errorBanner` is **not** present

---

## RS-11: Question TTS is actually attempted (and re-attempted after a playback failure)

**Type:** Unit (HangsTests) + Sim. Guards issue #59.1.

**Hypothesis:** Reaching `askingQuestion` must invoke question-audio playback
at least once, and a playback failure must NOT abort the quiz — the app still
reaches `recording` and TTS is re-attempted on the next question. (The real
59.1 bug is a missing `setActive(true)`; the spy proves the *attempt* fired,
the real-device confirm — out of loop — proves sound came out.)

**Preconditions**
- New seam on `MockAudioService`: `playOpusCallCount: Int` (+ `lastPlayedData: Data?`), incremented every `playOpusAudio`.
- Launch with `--ui-test`.

**Steps**
1. Tap `home.startQuiz`; wait for `question.state` label `askingQuestion`.
2. (Unit) Assert `mockAudio.playOpusCallCount >= 1`.
3. (Unit) Set `mockAudio.shouldFailPlayback = true`, advance one question, assert state reaches `recording` AND `playOpusCallCount` increments again on the next question.

**Asserts**
- `playOpusCallCount >= 1` after `askingQuestion`.
- With `shouldFailPlayback`, quiz still reaches `recording`; no `question.errorBanner`; TTS re-attempted next question.
- App process is alive; no `EXC_*` in log.

---

## RS-12: Answer/think countdown does not reflow pinned controls

**Type:** Sim (geometry). Guards issue #59.2.

**Hypothesis:** When `answerTimerCountdown`/`thinkingTimeCountdown` becomes
non-zero, the countdown chip must appear without shoving the question and
action row downward — the y-origin of `question.record` must stay put.

**Preconditions**
- Launch with `--ui-test`.

**Steps**
1. Tap `home.startQuiz`; wait for `askingQuestion`.
2. `snapshot_ui`; record `frame.origin.y` of `question.record` (y0).
3. Wait until the answer/think countdown chip is present (`answerTimerCountdown > 0`).
4. `snapshot_ui`; record `frame.origin.y` of `question.record` (y1).

**Asserts**
- `abs(y1 - y0) < 4` pt (no reflow).
- `question.record` still present and tappable.
- App process is alive; no `EXC_*` in log.

---

## RS-13: Tapping X with a dead backend session still returns Home (no stranding)

**Type:** Unit (HangsTests) + Sim. Guards issue #59.4.

**Hypothesis:** `endQuiz()` must treat a `NetworkError.sessionNotFound` (the
session is already gone) as success — clear session, reset state, stop audio,
return Home — and must NOT leave the user stranded on the question screen
behind a red banner.

**Preconditions**
- New seams on `MockNetworkService`: `endSessionError: Error?` (parallel to `createSessionError`) and `endSessionCallCount: Int`.
- Launch with `--ui-test`.

**Steps**
1. (Unit) Set `mockNetwork.endSessionError = NetworkError.sessionNotFound`; call `endQuiz()`.
2. (Sim) Tap `home.startQuiz`; reach `askingQuestion`; tap the close/X control mid-quiz.

**Asserts**
- (Unit) `quizState == .idle`, `currentSession == nil`, `errorMessage == nil`, `endSessionCallCount == 1`.
- (Sim) App returns to `HomeView` (`home.startQuiz` visible); `question.errorBanner` is **not** present.
- App process is alive; no `EXC_*` in log.

---

## RS-14: Replay button reflects audio availability (no dead interactive control)

**Type:** Unit (ViewInspector). Guards issue #59.5.

**Hypothesis:** `question.replay` must be disabled/absent when no question
audio is available (`currentQuestionAudioUrl == nil` or muted) so it never
looks tappable while silently no-opping; enabled only when replay can do
something.

**Preconditions**
- New VM computed prop `canReplayAudio` (`!settings.isMuted && currentQuestionAudioUrl != nil`).

**Steps**
1. (Unit) `currentQuestionAudioUrl == nil` → inspect `question.replay`.
2. (Unit) `currentQuestionAudioUrl != nil`, not muted → inspect `question.replay`.

**Asserts**
- nil URL (or muted) → `question.replay` is disabled (or absent).
- non-nil URL, not muted → `question.replay` is enabled.

---

## RS-15: Typed-answer submit shows a processing indicator before the result

**Type:** Sim (timing). Guards issue #59.6.

**Hypothesis:** Submitting a typed answer must show in-flight feedback
(`question.processingIndicator`) while the evaluation call runs — the screen
must not appear frozen until the result lands.

**Preconditions**
- New a11y-id `question.processingIndicator` in the typed-answer processing branch of the pinned controls.
- Launch with `--ui-test`.

**Steps**
1. Tap `home.startQuiz`; reach `askingQuestion`.
2. Open "Type answer instead", type `Paris`, tap send.
3. `snapshot_ui` within ~200 ms of submit.

**Asserts**
- `question.processingIndicator` is present before `question.state` becomes `showingResult`.
- App process is alive; no `EXC_*` in log.

---

## RS-16: Result read-aloud replays the question without disturbing the countdown

**Type:** Unit (HangsTests) + Sim. Guards issue #59.7.

**Hypothesis:** `ResultView` read-aloud must call the timer-safe
`replayQuestionAudio()` (not `playQuestionAudio`) — it plays the question
audio once and leaves the running auto-advance countdown untouched; tapping
it must not advance to the next question.

**Preconditions**
- `playOpusCallCount` spy from RS-11 in place.
- Launch with `--ui-test`.

**Steps**
1. (Unit) On the result screen, capture `autoAdvanceCountdown`; call `replayQuestionAudio()`.
2. (Sim) Reach `showingResult`; tap `result.readAloud`.

**Asserts**
- (Unit) `playOpusCallCount == 1` after the call AND `autoAdvanceCountdown` unchanged.
- (Sim) state stays `showingResult`; countdown value preserved (not reset/aborted).
- App process is alive; no `EXC_*` in log.

---

## RS-17: "Resume auto-advance" resumes the countdown, does not skip to next question

**Type:** Unit (HangsTests) + Sim. Guards issue #59.8.

**Hypothesis:** "Resume auto-advance" must call a dedicated
`resumeAutoAdvance()` (clear the pause flag, restart the countdown) and stay
on the result screen — it must NOT share `continueToNext()`, which jumps
straight to the next question.

**Preconditions**
- New VM method `resumeAutoAdvance()`.
- Launch with `--ui-test`.

**Steps**
1. (Unit) `pauseQuiz()` on a result, then `resumeAutoAdvance()`.
2. (Sim) Reach `showingResult`; pause (Stay here); tap "Resume auto-advance".

**Asserts**
- (Unit) `quizState == .showingResult` (NOT `askingQuestion`) AND `autoAdvanceCountdown > 0`.
- (Sim) still on the result screen after resume; countdown running.
- App process is alive; no `EXC_*` in log.

---

## RS-18: Media-mode audio session keeps the Bluetooth mic reachable

**Type:** Unit (HangsTests, pure helper — no live session, no hardware). Guards issue #59.3.

**Hypothesis:** The media audio mode must request `.allowBluetoothHFP` so the
AirPods microphone is reachable for recording — A2DP is output-only and
stripping HFP silently misroutes the mic.

**Reworked from the original "real `AudioService` + `setActive`" design:** calling
`setupAudioSession` activates a live `AVAudioSession` on the sim, which is the
suspected cause of the HangsTests hang that killed the autonomous loop
(2026-06-17). The option-building logic was extracted into the pure, non-isolated
`AudioService.categoryOptions(for:)` so the invariant is read back deterministically
with no session activation, permission prompt, or I/O. This is a *stronger* guard:
it pins the exact option set `setupAudioSession` applies, with zero hang surface.

**Preconditions**
- None — the helper is pure (no instance state, no session, no hardware).

**Steps**
1. Call `AudioService.categoryOptions(for: .media)` (and `.call`, `.default`).
2. Inspect the returned `AVAudioSession.CategoryOptions`.

**Asserts**
- Media options contain `.allowBluetoothHFP` (and still `.allowBluetoothA2DP`).
- `AudioMode.default` is `media` and carries HFP (pins the default against regression).
- Every mode ducks others + defaults to speaker.
- (Test body documents *why* HFP must stay: Bluetooth mic access, not phone-call UI — fails the instant anyone strips it.)

---

## Adding a scenario

1. Pick the next free `RS-NN`.
2. Write **hypothesis** as one sentence — what behavior protects what bug class.
3. List **preconditions** explicitly (no implicit state).
4. Steps must be deterministic — every wait has a max duration; no real audio.
5. Asserts include both positive (expected state) and negative (forbidden state).
6. Always assert "app process is alive" — that is the only crash signal we have.

When a scenario starts failing after a code change, fix the code, not the
scenario. If the scenario itself becomes wrong (the desired behavior
changed), update the hypothesis and bump nothing — the number stays.
