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
