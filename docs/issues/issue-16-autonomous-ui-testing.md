# Issue 16: Autonomous UI Testing for Hangs

**Status:** Planning → Implementation
**Created:** 2026-04-28
**Goal:** Enable Claude to autonomously regression-test the iOS app after every change to catch state/flow bugs and crashes before TestFlight.

---

## Problem

App is voice-first and chronically unstable. Recurring symptom classes:
- Recording doesn't auto-stop in some flows
- Wrong status messages shown in wrong states
- Crashes after recording or under specific timing
- New changes regress old fixes

Pure manual QA doesn't catch regressions. Pure unit tests don't catch screen-flow / view-coordinated bugs.

**Out of scope (explicit user decision 2026-04-28):** STT transcription accuracy, TTS audio quality. Those are tested manually.

---

## Architecture (already mapped)

State machine: `QuizState` enum + `validTransitions` table at `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:22`.

Protocols + DEBUG mocks already exist for the seams we need:
- `ElevenLabsSTTServiceProtocol` + `MockElevenLabsSTTService` (`Services/ElevenLabsSTTService.swift:26, 249`)
- `AudioServiceProtocol` + `MockAudioService` (`Services/AudioService.swift:34, 898`)
- `SilenceDetectionServiceProtocol` + `MockSilenceDetectionService`
- `NetworkServiceProtocol` + `MockNetworkService`

Accessibility identifiers already on most interactive elements (mic, statusPill, confirm, reRecord, skip, repeat, etc).

---

## Plan

### Commit 1: External event injection on Mock STT

**File:** `apps/ios-app/Hangs/Hangs/Services/ElevenLabsSTTService.swift`

Add to `MockElevenLabsSTTService` (DEBUG only):
- `func injectEvent(_ event: STTEvent) async` — yields to internal `eventContinuation`
- Make the continuation observable so external test driver can pump events

Keep existing `mockCommittedText` path for compatibility with existing unit tests.

### Commit 2: UI-test launch arg + service factory

**New file:** `apps/ios-app/Hangs/Hangs/UITestSupport.swift` (DEBUG only, `#if DEBUG`)

Responsibilities:
- Parse `CommandLine.arguments` for `--ui-test` flag and `--ui-test-mocks-file <path>` (optional config path)
- Expose `static let isUITesting: Bool`
- Provide a static factory `UITestSupport.makeMockServices() -> (NetworkServiceProtocol, AudioServiceProtocol, ElevenLabsSTTServiceProtocol, SilenceDetectionServiceProtocol?)` that wires deterministic mocks
- Expose a singleton-ish access point for the live mock STT instance so the URL handler can call `injectEvent` on it

**File modified:** `apps/ios-app/Hangs/Hangs/HangsApp.swift`

In DEBUG, when `UITestSupport.isUITesting`, construct `QuizViewModel` with mock services from the factory.

### Commit 3: URL scheme + handler

**File modified:** `apps/ios-app/Hangs/Hangs/Info.plist`

Add `CFBundleURLTypes` with scheme `hangs-test` (DEBUG-effective only, but iOS requires the entry in Info.plist).

**File modified:** `apps/ios-app/Hangs/Hangs/HangsApp.swift`

Add `.onOpenURL` handler that routes `hangs-test://` URLs to `UITestSupport.handleTestURL(_:)`. Routes to support:
- `hangs-test://stt/partial?text=foo` → `injectEvent(.partialTranscript("foo"))`
- `hangs-test://stt/committed?text=foo` → `injectEvent(.committedTranscript("foo"))`
- `hangs-test://stt/silence` → triggers silence path
- `hangs-test://stt/error?msg=x` → injects an error event
- `hangs-test://state/dump` → logs current QuizState as JSON to a known location for the test runner to read

In **release builds**, the URL scheme is registered but the handler no-ops.

### Commit 4: State-revealing accessibility identifiers

**Files modified:** `QuestionView.swift`, `AnswerConfirmationView.swift`, possibly `ResultView.swift`.

Add identifiers to:
- `errorBanner` → `"question.errorBanner"`
- `liveTranscript` card → `"question.liveTranscript"`
- `statusPill` label content already accessible via existing identifier; ensure it carries the **state name** in `accessibilityValue` (e.g., `"recording"`, `"processing"`, `"idle"`)
- Confirmation sheet's processing/transcript branches → `"confirmation.state.processing"` / `"confirmation.state.transcript"`

This lets XcodeBuildMCP read state from the accessibility tree without needing screenshots.

### Commit 5: Bug fixes uncovered by mapping

These are independent of the testing infra but worth fixing before we run scenarios — otherwise tests will trip on known issues.

- `QuestionView.swift:63` — replace `quizState == .processing && transcribedAnswer.isEmpty` derived bool with a single `@Published` source on the ViewModel (e.g., `confirmationViewState: ConfirmationViewState` enum).
- `QuizViewModel.startRecording()` — clear `errorMessage = nil` at entry.
- Consider folding `showAnswerConfirmation` into `QuizState` (add `case confirmingAnswer`) so it's not a parallel source of truth. **Defer to discussion** — bigger change.

### Commit 6: First regression scenarios

**New file:** `docs/testing/regression-scenarios.md`

3-5 scenarios covering known recurring bugs. Initial set (to be confirmed with user):

- **RS-01**: Recording stops on `committed_transcript` and reaches confirmation sheet without crash
- **RS-02**: Recording auto-stops on hard 15s timer when no STT events arrive
- **RS-03**: Stale `errorMessage` from previous attempt does not show on next mic tap
- **RS-04**: Rapid double-tap mic does not crash and lands in legal state
- **RS-05**: Cancelling confirmation sheet returns to `askingQuestion`, not stuck in `processing`

### Commit 7 (after MCP install): First agent run

User installs XcodeBuildMCP. Claude runs the scenarios end-to-end:
- Build app with `--ui-test` arg
- Launch in simulator
- For each scenario: drive via `simctl openurl` + accessibility tree assertions
- Stream logs, watch for `EXC_*` / Sentry crashes
- Output structured pass/fail report

---

## Risks & open questions

1. **`onOpenURL` may fire before `QuizViewModel` is ready** during cold start. Solution: queue URL events in `UITestSupport` until ViewModel registers.
2. **Token fetch in streaming path** — `MockNetworkService.fetchElevenLabsToken()` must return a fake non-empty token, otherwise streaming aborts before mock STT is exercised.
3. **`onOpenURL` is single-fire** — for "state dump" we need a write-to-disk side-channel since URL response can't return data. Alternative: log to a known file under `NSTemporaryDirectory()` that the test runner reads.
4. **Confirmation sheet state machine cleanup** (Commit 5 third bullet) is a structural change. May want a separate issue.

---

## Out of scope

- STT/TTS quality tests
- Audio corpus integration tests
- Computer Use (deferred — XcodeBuildMCP is enough)
- Maestro (deferred — defer until cross-platform need arises)
- CI integration of agent-driven tests (start as on-demand, automate later)
