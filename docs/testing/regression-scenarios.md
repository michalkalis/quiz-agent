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
