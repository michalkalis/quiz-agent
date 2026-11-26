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
`UITestSupport.startTestListener()`) for spoken answers and interruptions. The legacy
`hangs-test://` URL scheme handler is still wired and may work on real
devices, but iOS 26.3 simulator drops it (LaunchServices bug), so the
HTTP path is canonical.

| Curl | Effect |
|---|---|
| `curl -s "http://127.0.0.1:9999/stt/connected"`           | readiness ping (200 once the listener is up) |
| `curl -s "http://127.0.0.1:9999/stt/committed?text=foo"`  | the player says "foo" into the open recording: the real batch path uploads it and the mock server hears "foo" (#208.8). 404 when no recording is armed |
| `curl -s "http://127.0.0.1:9999/recording/interrupt"`     | an audio interruption (phone call) hits the recording |
| `curl -s "http://127.0.0.1:9999/command/send?text=start"` | a voice command |
| `curl -s "http://127.0.0.1:9999/network/condition?text=offline&calls=submitTextInput"` | the network changes while the app runs (#235.5): a `--ui-test-network` profile, `clear` brings it back; without `calls` every mock call and the game together's polls |
| `curl -s "http://127.0.0.1:9999/network/release"` | the calls held since launch with `--ui-test-network-hold <name,name>` answer (#235.5) |

State assertions read the label of the hidden static text element
`question.state` (values: `idle`, `startingQuiz`, `askingQuestion`,
`recording`, `processing`, `showingResult`, `finished`, `error`) and
the presence of `confirmation.state.{processing,transcript}`
identifiers on the sheet.

Crash detection: stream simulator log via XcodeBuildMCP, fail scenario
on any `EXC_*` signal or app-process exit.

Numbering: `RS-N` (Regression Scenario). Numbers are never recycled —
when a scenario is removed, its number is retired.

## Frozen suite (XCUITest, #180 track D — 2026-09-22)

Every scenario below that can be driven without a human/LLM in the loop is
frozen as an XCUITest in `HangsUITests/Regression/`, one method per number.
Run the whole suite with `scripts/run-rs-suite.sh [SIM_UDID]` (report lands in
`docs/testing/runs/RS-suite-<date>.md`) or a single class with
`xcodebuild test -scheme Hangs-Local -only-testing:HangsUITests/<Class>`.
The suite also runs in `ios-ci.yml` (the `Hangs-Local` Test action includes
`HangsUITests`). On-demand only — no scheduled run (founder 2026-09-16).

`/regression` (LLM-driven via XcodeBuildMCP) stays for **exploring new
scenarios**; once a scenario is verified it is frozen here, not re-driven.

| RS | Frozen as | Notes |
|---|---|---|
| RS-01 | `RSRecordingTests.testRS01…` | |
| RS-02 | `RSRecordingTests.testRS02…` | real 15 s auto-stop (not shortened under `--ui-test`) |
| RS-03 | `RSRecordingTests.testRS03…` | |
| RS-04 | `RSRecordingTests.testRS04…` | second tap lands on `question.stop` |
| RS-05 | `RSRecordingTests.testRS05…` | "Again" bridges askingQuestion → recording; `confirmation.cancel` only in the transcribing branch, never shown by the instant mock |
| RS-06 | `RSEditTests.testRS06…` | mock grades canned; asserts the flow, not the grade |
| RS-07 | `RSEditTests.testRS07…` | |
| RS-08 | `RSEditTests.testRS08…` | |
| RS-09 | `RSMCQTests.testRS09…` | 3 launches: exact, inflected (`Jupitera`), unmatched |
| RS-10 | `RSMCQTests.testRS10…` | `processing` is transient on the mock; asserts result + no sheet |
| RS-11 | unit only (`QuizViewModelTTSSpyTests`) | the sim half has no observable beyond RS-start |
| RS-12 | `RSResultTests.testRS12…` | countdown lives inside `question.record`; asserts its y stays put |
| RS-13 | `RSResultTests.testRS13…` | X opens an End-quiz dialog (label match, no ids on alert buttons); dead-session half is unit |
| RS-14 | unit only (ViewInspector) | by design |
| RS-15 | `RSResultTests.testRS15…` | flow only — the in-flight indicator is not observable on the instant mock |
| RS-16 | `RSResultTests.testRS16…` (+ unit) | control is `result.hearIt` |
| RS-17 | `RSResultTests.testRS17…` (+ unit) | one toggle `result.stayHere`; resume proven by the auto-advance firing |
| RS-18 | unit only (pure helper) | by design |
| RS-19 | `RSPaywallTests.testRS19…` | free wall shows monthly + pack + Restore (real StoreKit Testing products) |
| RS-20 | `RSPaywallTests.testRS20…` | Restore with nothing → `paywall.nothingToRestore` |
| RS-21 | `RSPaywallTests.testRS21…` | purchase → success branch, no `paywall.purchaseError` |
| RS-24 | `RSPackTests.testRS24…` (+ unit `PackProgressTests`) | alert buttons matched by label (system alert) |
| RS-25 | `RSDailyChallengeTests.testRS25…` (+ unit `QuizViewModelDailyChallengeTests`) | scripted mock challenge (`DailyChallengeFixtures`), questions skipped |
| RS-26 | `RSAppConfigTests.testRS26…` (+ unit `AppConfigStoreTests`) | DEBUG seed, no backend |
| RS-27 | `RSAppConfigTests.testRS27…` (+ unit `AppConfigStoreTests`) | DEBUG seed; the store link itself is not opened |
| RS-28 | `RSRoomTests.testRS28…` (+ unit `RoomViewModelTests`) | scripted mock room (`MockRoomService`), DEBUG seed |
| RS-29 | `RSRoomTests.testRS29…` (+ unit `RoomViewModelTests`) | scripted mock room; host driven over the test listener |
| RS-32 | `RSRoomTests.testRS32…` (+ unit `RoomViewModelSettingsTests`) | scripted mock room; rules start from the defaults every launch (`UITestSupport.roomSettingsDefaults`); the in-game sheet is covered by unit tests and the `roomRules` snapshot only |
| RS-33 | `RSSharedQuizTests.testRS33a/b/c…` (+ unit `SharedQuizFlowTests`, `SharedQuizLinkTests`) | link delivered over the test listener; mocks answer for the server (`SharedQuizFixtures`); the friend's quiz is not played to its end (the round end is covered by unit tests and the `completionShare` / `sharedQuizRanking` snapshots) |
| RS-35 | `RSNetworkTests.testRS35…` | `--ui-test-network-hold getUsage,syncEntitlements`, released over the test listener (a 3 s delay ran out during XCUITest's launch idle waits); app config is not on the mock network (it fails open) |
| RS-36 | `RSNetworkTests.testRS36…` | typed answer; the network is switched off and back over the test listener (`/network/condition`); waits out the app's real 24 s `TransientRetry` window, the suite's slowest new scenario |
| RS-37 | `RSNetworkTests.testRS37…` | build-87 tab-bar bug; slow `startQuiz` (3 s) |
| RS-38 | `RSNetworkTests.testRS38…` | `--ui-test-network server-error` on `startQuiz`, cleared over the test listener; found `error.root` stamped over `error.retry`/`error.home` (fixed in `ErrorView`) |
| RS-39 | `RSPaywallTests.testRS39…` | `--ui-test-purchase-fail` (the purchase mock throws) |
| RS-40 | `RSPaywallTests.testRS40…` | `--ui-test-purchase-cancel` (the purchase mock returns `.userCancelled`) |
| RS-41 | `RSRoomTests.testRS41…` | `/network/condition?text=offline` fails every mock call and the room's polls |
| RS-42 | `RSRoomTests.testRS42…` | Home button press; the host moves on over the test listener while the guest is away |
| RS-43 | `RSSharedQuizTests.testRS43…` | slow `startSharedQuiz` so the waiting link's start is seen on Home |
| RS-45 | `RSPaywallTests.testRS45…` (+ unit `SoloPaceAndRewardTests`) | `--ui-test-quota-mid-round` (the graded answer throws the 429 with a verdict); the timing of the paywall after the round end is unit only |
| RS-46 | `RSResultTests.testRS46…` | Home `home.quickGame` on, so the skip skips the result screen |
| RS-47 | `RSPaywallTests.testRS47…` (+ unit `VoiceAllowanceTests`) | `--ui-test-voice-limit` (every voice upload throws the 429 `voice_limit_reached`) |
| RS-48 | `RSResultTests.testRS48…` (+ unit `SilentModeTests`) | Home `home.silentMode` on ("No sound") |
| RS-start / correct / incorrect / long / mcq-long / mcq-long-options / paywall / pack-nav-start | `RegressionTests.testRS<Slug>` | older slug-named family, unchanged |
| (a11y) | `A11yIdentifierTests.testHomeMenuItemsAreLocatableByIdentifier` | #180 track E guard: SwiftUI Menu items still expose their identifier to XCUITest |

**Locators (#180 track E):** every query goes by `accessibilityIdentifier`;
`scripts/lint-a11y-ids.py` (in `ios-ci.yml`) rejects both an untagged control
in the app and a visible-text query in `HangsUITests`. The suite launches with
the UI pinned to English (`RSFlow.baseLaunchArguments`) so the two unavoidable
label matches — system alert buttons, the StoreKit sheet — stay deterministic.

**Identifier drift vs. the specs below:** `question.micButton` is
`question.record`/`question.stop`; there is no `confirmation.state.*` probe —
the sheet's branch is read from `confirmation.answer` (transcript) /
`confirmation.answerField` (editing); `result.readAloud` is `result.hearIt`;
Stay/Resume is one `result.stayHere` toggle. Page objects in
`HangsUITests/Pages/` carry the truth.

---

## RS-01: Recording stops on committed transcript

**Hypothesis:** After the player finishes the spoken answer and the server transcribes it, the app
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
  `curl -s "http://127.0.0.1:9999/recording/interrupt"` mid-recording

**Steps**
1. Tap `home.startQuiz`
2. Tap `question.micButton`; wait for `recording`
3. `curl -s "http://127.0.0.1:9999/recording/interrupt" >/dev/null`
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
7. `curl -s "http://127.0.0.1:9999/stt/committed?text=Rome&wait=180" >/dev/null &`
   (answers "Rome" the moment the new recording opens)
8. Tap `confirmation.reRecord`; wait for the curl to return

**Asserts**
- The sheet shows the new recording: `confirmation.answer` reads `Rome`, not `Berlin`
- `question.counter` still reads `1/10` and no result screen appeared
- `question.errorBanner` is **not** present

Why not assert `askingQuestion`/`recording` right after the tap: those
states last ~10 s (the re-recording ends without speech), while XCUITest
on CI sometimes waits a minute per step for the app to go idle once the
keyboard is up. The new answer's sheet stays until the player acts.
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

## RS-09: MCQ voice answer goes through confirmation

**Hypothesis:** A spoken MCQ answer goes through the **confirmation sheet**, not straight to
the result (issue #171 Track I, founder 2026-09-05, restoring #45 decision D4). Since #208.8 the
backend transcribes and places the answer among the options (#185 track G); the sheet shows
exactly what it heard. Confirm — by tap or by letting the 5 s auto-confirm expire (the spoken
"ok" is gone since 2026-11-22: silence confirms) — and the quiz reaches the result. A mishearing is therefore always correctable before
it is graded.

**Preconditions**
- Launch with `--ui-test --ui-test-mcq`
- `Question.previewMCQ` is loaded: "What is the largest planet?" options a=Mars b=Jupiter c=Saturn d=Neptune
- `thinkingTime = 1` (seeded by UITestSupport for `--ui-test-mcq`): recording auto-starts ~1-2s
  after question audio (no mic button in the redesigned UI)
- `UITestSupport` seeds `autoConfirmEnabled = false` under `--ui-test`, so the sheet waits for an
  explicit Confirm here. In a real build the 5 s auto-confirm (#171 Track F) would fire instead —
  same end state, which is why this scenario asserts the sheet and then confirms it by hand.

**Steps**
1. Tap `home.startQuiz`
2. Wait for `question.state` label `askingQuestion` (up to 5s)
3. Confirm `mcq.option.a` is present in the accessibility tree (MCQ screen rendered)
4. Confirm the answer `listen-bar` caption reads "Listening — say A–D or the answer" (#171 Track I3
   — answering with the option TEXT is supported, and the caption must say so)
5. Wait for `question.state` label `recording` (up to 5s — answer timer fires after ~1s)
6. `curl -s "http://127.0.0.1:9999/stt/committed?text=Jupiter" >/dev/null`
7. Wait up to 3s for `confirmation.answer` to appear
8. Tap `confirmation.confirm`
9. Wait up to 5s

**Asserts**
- After step 7: `confirmation.answer` reads `Jupiter` — what the server heard
- After step 7: `question.state` label is `processing` and **no** `submitTextInput` has fired yet
- After step 9: `question.state` label is `showingResult`
- `mcq.option.b` is present in the accessibility tree while the question is up (options still rendered)
- App process is alive; no `EXC_*` in log
- `question.errorBanner` is **not** present

**Variant:** replay step 6 with a free answer (`?text=something%20unrelated`) — the sheet
shows it unchanged.

---

## RS-10: MCQ tap answer submits and transitions to processing

**Hypothesis:** Tapping an MCQ option calls `submitMCQAnswer` at the tap (no delay since the
RS-10 flake fix: a 500 ms hand-off let the speech-start window end the open recording first)
and the ViewModel transitions to `processing`. This covers the tap-to-answer path that complements
the voice path tested in RS-09 — a tap is an explicit choice, so it submits directly and does NOT
go through the confirmation sheet the voice path uses (#171 Track I).

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

## RS-16: "Hear it" on the result reads the explanation and holds the result

**Type:** Unit (HangsTests) + Sim. Guards issue #59.7 (read-aloud jumped to the
next question) and the CI flake after #240.9.

**Hypothesis:** "hear it" (`result.hearIt`) reads the explanation, never advances,
and holds the auto-advance while it reads (`QuizViewModel.holdResultAutoAdvance`),
as any touch on the result does. Since #240.9 the countdown is 3 s after the
spoken verdict, so a hold that only came from the screen's tap gesture let an
activation without a touch (VoiceOver) leave mid-explanation, and the old
1.5 s wall-clock check raced the countdown.

**Preconditions**
- Launch with `--ui-test`.
- (Sim) Before confirming the answer, hold the spoken verdict's download
  (`network/hold?text=downloadAudio`), so no countdown can start before the tap.

**Steps**
1. (Unit, `ResultHearItHoldTests`, test clock) "hear it" during the spoken verdict
   and during the countdown, then run the clock past the countdown.
2. (Sim) Reach `showingResult`; tap `result.hearIt`; release the network.

**Asserts**
- (Unit) still `showingResult`, `isPaused`; Next still moves on from a held result.
- (Sim) `question.pause` reads "Continue" at once; the result and its verdict stay.
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
- Every mode stops other audio (no mixing, no ducking — #243.1) + defaults to speaker.
- (Test body documents *why* HFP must stay: Bluetooth mic access, not phone-call UI — fails the instant anyone strips it.)

---

## RS-19: Free wall shows purchasable plans and Restore

**Type:** XCUITest (`RSPaywallTests`). Products come from `Hangs.storekit`
attached to the `Hangs-Local` scheme — real StoreKit Testing, not a mock.

**Hypothesis:** The quota wall must offer a way out: monthly plan row, pack
row, an enabled purchase CTA, Restore and Close — all addressable. A paywall
that renders but cannot sell (offline branch while StoreKit works) is the
#171/#174 TestFlight-round class of bug.

**Preconditions:** launch with `--ui-test --ui-test-paywall` (createSession
throws the free-limit error).

**Steps:** tap `home.startQuiz`; wait ≤15 s for `paywall-purchase-button`.

**Asserts:** `paywall-plan-monthly`, `paywall-plan-pack`, `paywall-restore-button`,
`paywall-close-x-button` exist; purchase CTA enabled; the offline branch
(`paywall-offline-retry-button`) is a FAIL. App alive.

---

## RS-20: Restore with nothing to restore is honest

**Type:** XCUITest (`RSPaywallTests`).

**Hypothesis:** Restore on an account with no purchases ends in the
"nothing to restore" notice on the same sheet — not a silent no-op, not a
fake success, not a dismissed paywall.

**Steps:** RS-19 preconditions; tap `paywall-restore-button`; wait ≤15 s.

**Asserts:** `paywall.nothingToRestore` present; `paywall.success.headline`
absent; `paywall-purchase-button` still present. App alive.

---

## RS-21: Purchase reaches the success state

**Type:** XCUITest (`RSPaywallTests`).

**Hypothesis:** Confirming the StoreKit Testing purchase sheet lands the
paywall in its success (or activating) branch with no purchase error — the
entitlement reconciles from the test transaction.

**Steps:** RS-19 preconditions; tap `paywall-purchase-button`; confirm the
system purchase sheet (looked up in the app, then on SpringBoard); wait ≤20 s.

**Asserts:** `paywall.success.headline` or `paywall.activating.headline`
present; `paywall.purchaseError` absent. App alive.

---

## RS-22: Forced update covers the app

**Type:** XCUITest (`RSAppConfigTests`). #193 task 193.9.

**Hypothesis:** Below the server's minimum version (`MIN_APP_VERSION_*`) the
player lands on the update screen with a way to the store, and Home is not
reachable behind it.

**Steps:** launch with `--app-config-update-required` (DEBUG seed, no backend).

**Asserts:** `update.message` and `update.open` present; `home.startQuiz` not
hittable. App alive.

---

## RS-23: Notice dismisses; paused orders disable Create a pack

**Type:** XCUITest (`RSAppConfigTests`). #193 task 193.9.

**Hypothesis:** The server notice on Home can be closed, and
`PACK_ORDERS_ENABLED=false` keeps both create-pack entries (Home card and
Settings row) visible but disabled.

**Steps:** launch with `--app-config-notice --app-config-orders-off`; tap
`home.notice.dismiss`; check the Home card; open Settings.

**Asserts:** `home.notice.text` present, then gone after dismiss;
`home.createPack` present and disabled; `packs.createPack` disabled. App alive.

---

## RS-24: A played-through pack asks before it starts over

**Type:** XCUITest (`RSPackTests`). #200 (founder TF test 2026-10-12).

**Hypothesis:** A custom pack remembers what this phone played: its Home card
shows the played count, and starting a pack played through asks "Play this
pack again from the start?" instead of failing with a raw server error.

**Steps:** launch with `--ui-test-pack-played-through` (every question of the
mock's delivered pack marked played); tap `home.myPacks.play`; tap
"Start over" in the alert.

**Asserts:** `home.myPacks.progress` present; the alert appears and no
question is on screen behind it; after "Start over" `question.text` appears.
App alive.

---

## RS-25: The daily challenge plays through to its own round end

**Type:** XCUITest (`RSDailyChallengeTests`). #205 (daily challenge: player vs the crowd).

**Hypothesis:** The daily challenge plays through the ordinary quiz screens,
shows the crowd strip only on the answers the server sent one for, ends on
its own round end (Share icon, Next quiz + Home, never Play Again), and back on Home the day
shows as played instead of being offered again.

**Steps:** launch with `--ui-test-daily-home` (server switch on, a scripted
five-question challenge on the mocks); tap `home.daily.play`; skip each of
the five questions and continue from each result; tap `daily.home`.

**Asserts:** `result.crowd` present on results 3 and 4, absent on 1, 2 and 5;
`daily.end`, `daily.tiles`, `daily.share` and `daily.nextQuiz` present, `completion.playAgain`
absent; back Home `home.daily.open` present and `home.daily.play` gone. App
alive.

---

## RS-26: Maintenance covers the app

**Type:** XCUITest (`RSAppConfigTests`). #214.

**Hypothesis:** With the server's maintenance switch on, the player sees the
maintenance message over the whole app instead of starting a quiz that fails.

**Steps:** launch with `--app-config-maintenance` (DEBUG seed, no backend).

**Asserts:** `maintenance.message` present; `home.startQuiz` not hittable. App alive.

---

## RS-27: Update card on Home offers the store and dismisses

**Type:** XCUITest (`RSAppConfigTests`). #214.

**Hypothesis:** Below the recommended version the update stays optional: the
card offers the store, closes, and Home stays playable.

**Steps:** launch with `--app-config-update-recommended`; tap `home.update.dismiss`.

**Asserts:** `home.update.open`, `home.update.dismiss` and `home.startQuiz`
present; card gone after dismiss. App alive.

---

## RS-28: The host plays a whole game together

**Type:** XCUITest (`RSRoomTests`). #212 (game together in one room).

**Hypothesis:** The host's phone drives the game for everyone (read, open,
next); a stalled step would leave every phone on one question.

**Steps:** launch with `--app-config-multiplayer`; tap the Together tab (`tab.together`),
`room.host`; give a name if asked; pick `room.rules.reveal` →
`room.rules.reveal.question` (#240.9: now also the default);
`room.start`; tap option B; `room.next`;
type "Canberra" and send; `room.next`; `room.done`.

**Asserts:** `room.qr` and `room.player.p_other` in the lobby; `room.reveal.answer`
after each question; `room.final.winner` is the host; `room.final.away`,
`room.final.award.fastest`, `room.playAgain` and `room.final.share` present (#240.9); back on Home. App alive.

---

## RS-29: A guest joins by link and follows the host

**Type:** XCUITest (`RSRoomTests`). #212.

**Hypothesis:** A join link opens the game from Home; a guest answers, sees
each reveal, waits for the host and never sees host-only controls.

**Steps:** launch with `--app-config-multiplayer`; POST `/room/join?text=mock-token`
to the test listener; `/room/start`; tap option B; `/room/next`; type
"Sydney" and send; `/room/next`.

**Asserts:** `room.lobby.rename` after the link; `room.reveal.answer` and
`room.waitingForHost` after question 1, `room.next` absent; `room.final.winner`
present, `room.final.away` absent. App alive.

---

## RS-30: Profile: plan, All stats, Settings under the gear; a quiz hides the tab bar

**Type:** XCUITest (`RSProfileTests`). #213.4 (tab bar and Profile), #216.3
(plan moved to Profile, stat cards behind All stats).

**Hypothesis:** Settings opens from the gear on Home (TestFlight build 90
feedback: Home had no way in) and from the Profile's gear; the plan now lives on the Profile, the stat cards behind "All stats"
(open and locked, without the retired ones); a quiz keeps the full screen with
no tab bar to wander off to.

**Steps:** launch (mock stats: a seasoned player); tap `home.settings`, then
back; tap `tab.profile`; tap
`profile.allStats`, then back; tap `profile.settings`; tap `tab.play`; start a
quiz.

**Asserts:** `settings.voiceCommands` after the Home gear, back on Home;
`home.planLabel` absent on Home;
`home.planLabel` on the Profile; `profile.myPacks` absent;
`profile.card.totals` in All stats, `profile.card.hard_questions` absent;
`settings.voiceCommands` after the gear; `tab.profile` not hittable on the
question screen. App alive. RS-pack-nav-start now opens Settings the same way
and so also covers a quiz started from the Profile landing on Play.

---

## RS-31: The recap card shows on the Profile with Share

**Type:** XCUITest (`RSProfileTests`). #213.5 (recap and sharing), #216.3
(one card instead of the story).

**Hypothesis:** the monthly recap is the reason to come back; it is one card on
the Profile with Share ready (the picture rendered).

**Steps:** launch (mock: a seasoned player with an unseen October recap); tap
`tab.profile`.

**Asserts:** `profile.recap` and `recap.share` present. App alive.

---

## RS-32: The host sets the rules in the lobby; a guest only reads them

**Type:** XCUITest (`RSRoomTests`). #213.8 (rules for a game together).

**Hypothesis:** the rules hold for every phone, so a first game starts from
the group defaults (not the host's solo choices), a change shows at once,
and a guest sees the host's rules without any control to change them.

**Steps:** launch with `--app-config-multiplayer`; tap the Together tab (`tab.together`),
`room.host`; give a name if asked; tap `room.rules.time` →
`room.rules.time.45`. Relaunch; POST `/room/join?text=mock-token` to the
test listener.

**Asserts:** `room.rules.reveal` reads "After each question",
`room.rules.time` "15 s" (#240.9 defaults), `room.rules.readsAloud` present; after the pick
`room.rules.time` reads "45 s". Guest: `room.rules.guest` present;
`room.rules.reveal`, `room.rules.time`, `room.rules.readsAloud` absent. App
alive (both launches).

---

## RS-33: A shared quiz link plays once, then compares

**Type:** XCUITest (`RSSharedQuizTests`). #232 (share a quiz by link).

**Hypothesis:** A friend's link starts its quiz at once from Home; a link the
player cannot play again (already played, or the sender's own) shows the
comparison instead of an error or a second attempt.

**Steps:** launch with `--app-config-shared-quiz` (a: no other flag; b:
`--ui-test-shared-quiz-played`; c: `--ui-test-shared-quiz-own`); POST
`/shared/open?text=rs33-shared-quiz` to the test listener; in b and c tap
`sharedQuiz.results.done`.

**Asserts:** a: the question screen, no `sharedQuiz.ranking`. b, c:
`sharedQuiz.ranking` present, no question, back on Home (`home.startQuiz`)
after Done. App alive.

---

## RS-34: A slow start shows Cancel, then the question

**Type:** XCUITest (`RSNetworkTests`). #235.1 (a "bad network" switch for
tests).

**Hypothesis:** on a slow server the quiz start stays visibly in flight and
cancellable on Home (the window in which a player can walk to another tab,
founder build 87), and the question still arrives once the server answers.

**Steps:** launch with `--ui-test-network slow --ui-test-network-delay 4
--ui-test-network-calls startQuiz` (the first question comes 4 s late; see
`MockNetworkService+Conditions.swift` for the other profiles: `timeout`,
`offline`, `dropped`, `server-error`, `malformed`); tap `home.startQuiz`.

**Asserts:** `home.cancelStart` present and hittable while the start is in
flight, `question.text` absent; then `question.text` present, `question.state`
reads `askingQuestion`, `home.cancelStart` gone. App alive.

---

## RS-35: A slow launch keeps Home usable

**Type:** XCUITest (`RSNetworkTests`). #235.5 (degraded conditions).

**Hypothesis:** usage and the entitlement sync answering late (cold server,
weak signal) must not block Home: Start and the tab bar work the whole time,
the plan says it is loading, then settles to the player's real plan.

**Steps:** launch with `--ui-test-plan-subscriber --ui-test-network-hold
getUsage,syncEntitlements` (both stay in flight); tap `tab.profile`, then
`tab.play`; POST `/network/release`; tap `tab.profile`.

**Asserts:** while held: `home.startQuiz` and `tab.profile` hittable,
`home.freePlanLoading` on the Profile, `home.startQuiz` hittable back on Play;
after release `home.planManageButton`, loading gone, no
`home.freePlanRetryButton`. App alive.

---

## RS-36: The network drops while answering; retry keeps the question

**Type:** XCUITest (`RSNetworkTests`). #235.5.

**Hypothesis:** an answer sent into a dead connection never vanishes
silently: while the app retries on its own (24 s) the screen says it is
processing, then an error with Try again and a way Home; Try again with the
network back reopens the same question and the answer is graded.

**Steps:** launch; start a quiz; POST `/network/condition?text=offline&calls=submitTextInput`;
type "Paris" and send; wait ≤40 s; POST `/network/condition?text=clear`; tap
`error.retry`; type "Paris" and send.

**Asserts:** probe `processing` after the send; `error.title`, `error.retry`,
`error.home` present and no result; after Try again the probe reads
`askingQuestion` with the same `question.text`; then the result with
"Nailed it" and no error screen. App alive.

---

## RS-37: A slow start finishes on the question after a tab switch

**Type:** XCUITest (`RSNetworkTests`). #235.5; the build-87 bug (PR #799).

**Hypothesis:** a quiz started on a slow server lands on its question even
when the player walked to the Together tab meanwhile, and ending that quiz
brings the tab bar back (on build 87 it vanished and the app had to be killed).

**Steps:** launch with `--app-config-multiplayer --ui-test-network slow
--ui-test-network-delay 3 --ui-test-network-calls startQuiz`; tap
`home.startQuiz`; tap `tab.together` while `home.cancelStart` shows; wait for
the question; X → "End Quiz".

**Asserts:** `question.text` present with the probe at `askingQuestion`;
after ending, `tab.together` present and hittable. App alive.

---

## RS-38: A failed start offers Try again and Home

**Type:** XCUITest (`RSNetworkTests`). #235.5.

**Hypothesis:** a server error on the start ends in an error the player can
act on, and Home works afterwards. (First run found both buttons carrying the
screen's `error.root` identifier; `ErrorView` now keeps its children's ids.)

**Steps:** launch with `--ui-test-network server-error
--ui-test-network-calls startQuiz`; tap `home.startQuiz`; tap `error.home`;
POST `/network/condition?text=clear`; start a quiz.

**Asserts:** `error.title`, `error.retry`, `error.home` present, no
`question.text`; Home with `tab.profile` after `error.home`; the next start
reaches the question. App alive.

---

## RS-39: A failed purchase says so and grants nothing

**Type:** XCUITest (`RSPaywallTests`). #235.5.

**Hypothesis:** when the store reports a failure the paywall says so and
stays usable, claims no success, and the free wall still stands.

**Steps:** launch with `--ui-test-paywall --ui-test-purchase-fail`; tap
`home.startQuiz`; tap `paywall-purchase-button`; tap ✕; tap `home.startQuiz`.

**Asserts:** `paywall.purchaseError` present; no `paywall.success.headline` /
`paywall.activating.headline`; purchase CTA enabled and ✕ hittable; the next
start shows the paywall again, no question. App alive.

---

## RS-40: A cancelled purchase returns to the paywall quietly

**Type:** XCUITest (`RSPaywallTests`). #235.5.

**Hypothesis:** closing the store sheet is the player's choice, not a
failure: the paywall comes back as it was, no error, no entitlement.

**Steps:** RS-39 with `--ui-test-purchase-cancel` instead of the fail flag.

**Asserts:** purchase CTA enabled again; no `paywall.purchaseError`; the rest
as RS-39. App alive.

---

## RS-41: The host loses the network mid-game

**Type:** XCUITest (`RSRoomTests`). #235.5.

**Hypothesis:** the host's phone drives the game, so a dead connection must
show, the game goes on by itself when the network is back, and the host can
leave at any time.

**Steps:** launch with `--app-config-multiplayer`; host a game (per-question
reveal) and start it; on question 1 POST `/network/condition?text=offline`;
then `?text=clear`; tap option B; `room.close` → "End game".

**Asserts:** `room.connection` appears while offline and `room.close` is
hittable; `room.connection` gone after the network is back; the reveal
(`room.reveal.count`) after the answer; back on the Together tab
(`room.host`) after ending. App alive.

---

## RS-42: A guest back from the background sees the current question

**Type:** XCUITest (`RSRoomTests`). #235.5.

**Hypothesis:** a guest who switched apps while the host moved on comes back
to the question the room is on, not the stale reveal.

**Steps:** launch with `--app-config-multiplayer`; POST `/room/join?text=mock-token`,
`/room/start`; tap option B; press Home; POST `/room/next`; bring the app back.

**Asserts:** `room.answer.field` (question 2) present; `room.reveal.count`
and `room.waitingForHost` absent. App alive.

---

## RS-43: A shared quiz link during a running quiz waits for it to end

**Type:** XCUITest (`RSSharedQuizTests`). #235.5.

**Hypothesis:** a friend's link tapped mid-quiz neither throws away the quiz
being played nor leaves a stuck screen: the link waits and starts the
friend's quiz once the player is back on Home (today's behaviour, by design
in `ContentView.openPendingSharedQuiz`).

**Steps:** launch with `--app-config-shared-quiz`; start a quiz; POST
`/network/condition?text=slow&calls=startSharedQuiz` (so the friend's start is
visible); POST `/shared/open?text=rs33-shared-quiz`; X → "End Quiz".

**Asserts:** for 2 s after the link the probe stays `askingQuestion`,
`question.text` present, no `sharedQuiz.ranking`; after ending,
`home.cancelStart` (the friend's quiz starting without a tap), then
`question.text` at `askingQuestion`. App alive.

---

## RS-44: A round with kids plays through the existing game screens

**Type:** XCUITest (`RSFamilyRoundTests`). #236 (family section „S deťmi“);
founder 2026-11-18: the game keeps its existing UI for a family round.

**Hypothesis:** a round started from „S deťmi“ asks for the band's round
(6 questions for 4–6, 10 otherwise), plays through the ordinary question,
result and round end screens (also when the start says it `repeats` played
questions), offers no "Send to a friend" (the server refuses to share a
round with kids), and Play Again replays the family round.

**Steps:** (a) launch with `--app-config-family --ui-test-family-repeats
--app-config-shared-quiz`; tap the "With kids" segment of `home.mode`,
`family.band.kids_4_6`, `home.startFamily`; tap `mcq.option.a` on each of
6 questions, continuing from each result; tap `completion.playAgain`.
(b) launch with `--app-config-family`, pick `family.band.kids_7_9`, skip 10
questions, tap `completion.home`.

**Asserts:** `question.counter` reads `1/6` (a), `1/10` (b), and `1/6` again
after Play Again with choices on screen (an adult round would bring the adult
mock question); `completion.playAgain` and `completion.home` present,
`completion.sendToFriend` absent; back Home `home.startFamily`. App alive.

---

## RS-45: The monthly limit reached on an answer shows its verdict and the round end first

**Type:** XCUITest (`RSPaywallTests`). #240.9 (founder 2026-11-18).

**Hypothesis:** when an answer reaches the monthly limit, the server grades
it and sends the verdict with its 429; the player sees that verdict, then the
end of the round, and only then the paywall, which closes back onto the end
of the round (the app used to drop the verdict and show only the paywall).

**Steps:** launch with `--ui-test-quota-mid-round`; start a quiz, record
"Paris" over the test listener (the graded upload answers with the 429, no
confirmation sheet); wait for the round end; wait for the paywall; tap
`paywall-close-x-button`.

**Asserts:** `result.verdict` present with no paywall; `completion.highlight`
appears with no paywall; the paywall follows (purchase or offline branch);
after ✕ `completion.home` is on screen. App alive.

---

## RS-46: An open answer field closes when a quick skip moves on

**Hypothesis:** A quick-game skip goes to the next question without the
result screen, so the question screen stays up; the answer field the player
opened must still close when the next question arrives (founder, TestFlight
build 90: the field stayed open, Type greyed out).

**Preconditions:** `--ui-test`; Home `home.quickGame` switched on.

**Steps:** start a quiz, tap `question.textInputToggle`, wait for
`question.textField`, tap `question.skip`.

**Asserts:** `question.textField` is gone within 10 s;
`question.textInputToggle` is enabled. App alive.

---

## RS-47: Voice answers used up: told once, the quiz goes on by typing

**Type:** XCUITest (`RSPaywallTests`). Free tier split (founder 2026-11-21, D1).

**Hypothesis:** a voice answer past the month's free voice answers is refused
by the server (429 `voice_limit_reached`, nothing charged); the question stays
on screen with one notice and a quiet Plus link that never blocks it, and
Answer leads to typing instead of the refused mic.

**Preconditions:** `--ui-test --ui-test-voice-limit` (every voice upload gets
the 429).

**Steps:** start a quiz, tap `question.record`, say "Paris" over the test
listener; wait for `question.voiceLimitNotice`; tap `question.voiceLimitPlus`,
wait for the paywall, tap its ✕; tap `question.record` again; type "Paris"
into `question.textField`, tap `question.textSubmit`.

**Asserts:** the notice appears and the state probe reads `askingQuestion`
with no paywall; closing the paywall lands back on the question; the second
Answer tap opens `question.textField` and the probe stays `askingQuestion`
(no mic); the typed answer reaches the result. App alive.

---

## RS-48: A silent quiz is answered by typing, without a time limit

**Type:** XCUITest (`RSResultTests`). "No sound" (founder 2026-11-22).

**Hypothesis:** with the Home "No sound" switch on, nothing reads, listens or
counts down: the question opens with the typed field ready, the mic never
opens by itself, and the typed answer reaches a result that offers nothing
to hear.

**Preconditions:** `--ui-test`; Home `home.silentMode` switched on.

**Steps:** start a quiz; wait 5 s on the question; type "Paris" into
`question.textField`, tap `question.textSubmit`.

**Asserts:** `question.textField` exists at once; `question.record` and
`question.textInputToggle` do not; after 5 s the probe reads `askingQuestion`,
no `question.stop`, no `listen-bar`; the result appears without
`result.hearIt`. App alive.

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

## On-device checks before a release

No simulator covers these (#235.5). Run them on a phone with a TestFlight build; system interruptions in detail: the checklist in `docs/testing/system-calls-coverage.md` (arriving with PR #816).

1. Weak signal: start a quiz on Wi-Fi, walk away from it mid-question and answer. Expected: progress, then the answer is graded or an error with Try again; never a frozen screen.
2. Car Bluetooth: connect the car while a question is read, disconnect while recording. Expected: audio moves to the car and back, the quiz keeps its question and a way to answer.
3. Phone call: take a call while a question is read, then another while recording. Expected: reading and recording stop; after the call the question is still there and can be answered.
4. Siri / alarm: trigger Siri and let an alarm ring mid-question. Expected: the same as a call, no crash, no lost question.

