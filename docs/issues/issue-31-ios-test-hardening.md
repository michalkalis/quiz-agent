# Issue 31: iOS test hardening — lock in current behavior

**Triage:** enhancement · ready-for-human
**Status:** Strategy drafted 2026-05-06 — decisions needed before agent run (see end)
**Created:** 2026-05-06
**Surfaced by:** test-coverage review

## TL;DR

App is in a usable, shippable state. Before further refactors land, lock that
state in with tests so regressions are caught at the test layer, not by users.

Today: 9 test files (~2 375 lines) vs ~15 600 lines of production code (~15 %
test/code ratio). Unit tests centre on `QuizViewModel` state machine. Gaps
cluster around **revenue** (`StoreManager` = 0 tests), **voice pipeline
internals** (`ElevenLabsSTTService`, `SilenceDetectionService`, streaming
recorder), **`NetworkService` HTTP construction**, and **UI** (`HangsUITests`
are Xcode stubs).

Goal: raise meaningful coverage on the highest-risk untested paths without
chasing 100 %. Every new test must answer "what specific regression would
this catch?" in one line. If the answer is vague, don't write it.

## Audit — what's tested vs not

### Tested today (Swift Testing, ~2 375 lines)

| File | Covers |
|---|---|
| `QuizViewModelTests.swift` (1367) | State machine, MCQ, answer timers, settings persistence, `QuizStats` math, double-stop guard |
| `AudioServiceTests.swift` (200) | `AudioError` strings, `MockAudioService`, `PlaybackState` equality |
| `AudioFixtureTests.swift` (119) | Three bundled fixtures (size, header bytes) |
| `NetworkDecodingTests.swift` (196) | `Question` Codable, `Evaluation`, `SafeCollection` |
| `PersistenceStoreTests.swift` (237) | Session id, settings, history (CRUD, dedup, cap), corrupt-JSON fallback |
| `TaskBagTests.swift` (165) | Replace-on-key, cancel, idempotency |

Mocks (`MockNetworkService`, `MockAudioService`, `MockPersistenceStore`,
`MockSilenceDetectionService`, `MockElevenLabsSTTService`) live in production
files behind `#if DEBUG`. UI-test seam: `UITestSupport.swift` + HTTP listener
on `127.0.0.1:9999`. Real UI coverage today: only the `/regression` skill
driving RS-01..RS-08 manually.

### Not tested

**Critical (revenue / state correctness):**
- `StoreManager.swift` — 0 tests. `purchase()`, `restorePurchases()`,
  `Transaction.updates` listener, `isPurchased` gate.
- `ElevenLabsSTTService.swift` — 0 tests. `handleMessage` parser
  (partial/committed transcript, error), URL/VAD config construction.
- `SilenceDetectionService.swift` — 0 tests. Three-state machine + 1.5 s
  threshold.
- `NetworkService.swift` — 0 tests on the concrete actor.
  `NetworkError.dailyLimitReached` 429 decoding, `downloadAudio` Content-Length
  integrity check, `extendSession`, `rateQuestion`, `flagQuestion`,
  `getUsage`, `setPremium`.
- `QuizStats` round-trip through `PersistenceStore` — never asserted
  end-to-end.

**Important (voice + UI flows):**
- `QuizViewModel+Recording.swift` ElevenLabs streaming path:
  `startStreamingRecording`, PCM chunk loop, committed-transcript handler.
- `QuizViewModel+Timers.swift` — `startAutoAdvance` and
  `startAutoStopRecordingTimer` have no unit test (only the answer
  countdown is tested).
- `resubmitAnswer` with `transcriptWasEdited=true` (text path that
  suppresses TTS).
- Exclusion-list wiring (`startQuiz(excludedQuestionIds:)`).
- `QuizSettings` backward-compat decoder (legacy persisted state).
- `HangsUITests` — Xcode stubs.

**Low priority:** `LogStore`, `Config`, theme/font, debug views.

### Quality smells in existing tests

- **Mock copy-paste**: full `QuizSession + Participant + MockNetworkService`
  block repeated 4× in `QuizViewModelTests.swift` (lines 290–328, 596–630,
  1076–1123, 1312–1342). A `makeFullMockNetwork()` factory removes ~200 lines.
- **`RecordingValidationTests`** (`AudioServiceTests.swift:126`): asserts on
  local constants only, never calls into production code. False-positive
  coverage.
- **`MockAudioServiceTests`** (`AudioServiceTests.swift:43–119`): tests the
  mock, not `AudioService`. Useful as mock-contract test, misleading by name.
- **`HangsTests.swift`** stub `@Test func example()` — no body.
- **`Task.yield()`** wait for Combine sink (`QuizViewModelTests.swift:946`) —
  fragile under CI load.
- **`UserDefaults` test suites** in `PersistenceStoreTests` aren't cleaned up.
- **Implementation-detail assertion** in
  `rerecordRestartsTimerWithBonus` (line 905): asserts the literal `+10`
  bonus; couples test to a magic number.

## Research — picks for Hangs

(Full digest in conversation history; key choices below.)

- **Swift Testing** for new unit tests (already adopted). Keep XCTest only for
  XCUITest. No mass migration.
- **`swift-concurrency-extras`** (Pointfree): `withMainSerialExecutor` makes
  state-machine async tests deterministic — eliminates `Task.yield()` flakiness.
- **`swift-snapshot-testing`** (Pointfree): use **text-dump / accessibility-tree**
  strategy, not image. Avoids simulator-version drift on solo CI.
- **StoreKitTest framework** + `.storekit` config file: test the paywall
  offline; `SKTestSession` lets us script renewals/cancellations.
- **`ViewInspector`**: in-process SwiftUI assertions for components — no
  simulator boot.
- **XcodeBuildMCP `test_sim`**: structured per-method JSON output. Switch
  `/regression` from HTTP-listener-only to `test_sim` first, listener fallback
  for scenarios XCUITest can't express.
- **Reference repos**: isowords (snapshot patterns for state-machine UI),
  Kickstarter iOS (single `Environment` mock-injection pattern).

## Strategy — five phases

### Phase 1 — Foundation (1–2 days)
Set up infra. No behaviour change.

- Add SPM deps to test target: `swift-concurrency-extras`,
  `swift-snapshot-testing`, `ViewInspector`.
- Add `Hangs/Configuration/Hangs.storekit` with the premium subscription
  product. Wire `Hangs-Local` scheme to use it.
- Create `HangsTests/Support/Fixtures.swift` with shared mock factories
  (`makeFullMockNetwork()`, `makeQuizSession()`, `makeQuestion()`,
  `makeQuizSettings()`).
- Replace mock copy-paste in `QuizViewModelTests` with `Fixtures` (cuts ~200
  lines).
- Delete `HangsTests/HangsTests.swift` (empty stub) and
  `RecordingValidationTests` (false-positive). Rename `MockAudioServiceTests`
  → `MockAudioServiceContractTests` (honest name).
- Add `.accessibilityIdentifier(_:)` to every interactive element in
  `HomeView`, `QuestionView`, `ResultView`, `AnswerConfirmationView`,
  `SettingsView`, `PaywallView`. Stable selectors for phase 5.

**Exit:** existing tests pass; `Fixtures.swift` shared; CI green.

### Phase 2 — Lock in critical paths (2–3 days)
Five highest-risk untested areas. One file per service. Each test PR-sized.

- `StoreManagerTests.swift` — `SKTestSession`-based: load products, purchase
  success, purchase cancel, purchase pending, transaction observer flips
  `isPurchased`, restore.
- `ElevenLabsSTTServiceTests.swift` — `handleMessage` parser with canned
  WebSocket JSON: `partial_transcript`, `committed_transcript`,
  `session_started`, `error`. URL construction asserts (VAD config, query
  params, language).
- `SilenceDetectionServiceTests.swift` — three-state machine `idle →
  speechActive → silenceAccumulating → emit`; threshold boundary (1.4 s vs
  1.5 s vs 1.6 s).
- `NetworkServiceTests.swift` — `URLProtocol`-stubbed:
  `NetworkError.dailyLimitReached` decoded from 429 +
  `DailyLimitErrorWrapper`; `downloadAudio` Content-Length mismatch raises
  `NetworkError.audioIntegrity`; happy-path bodies for `extendSession`,
  `rateQuestion`, `flagQuestion`, `getUsage`, `setPremium`.
- Extend `PersistenceStoreTests.swift` — `QuizStats` save/load round-trip +
  corruption fallback.

**Exit:** five new test files green; CI green; all seven seams from
Task 1.6 (handoff) verified non-breaking. *(Updated 2026-05-07 — dropped
"test/code ratio ≥ 25 %"; chase risk, not numbers.)*

### Phase 3 — Voice + timer pipeline (2–3 days)
State machine well-tested; recording subsystem isn't. Use
`withMainSerialExecutor` for determinism.

- `QuizViewModelStreamingTests.swift` — `startStreamingRecording` happy path,
  partial transcript updates, committed-transcript transitions to
  `processing`, error returns to `askingQuestion`.
- `QuizViewModelTimerTests.swift` (split out from
  `QuizViewModelTests.swift`) — `startAutoAdvance` + cancel-on-mic-tap;
  `startAutoStopRecordingTimer` 15 s safety; `startThinkingTimeCountdown`
  cancellation on early submit; barge-in (`handleBargeIn`) cancels TTS +
  transitions to `recording`.
- `resubmitAnswer` text path (`transcriptWasEdited=true`) — no TTS replay,
  transitions to `showingResult`.
- Exclusion-list wiring — `startNewQuiz` calls `getExclusionList()` and
  forwards IDs to network.
- `QuizSettings` backward-compat — decodes legacy JSON missing
  `thinkingTime`, `autoConfirmEnabled`, `showConfirmSheet`, `isMuted`,
  `ageAppropriate`.
- Replace `Task.yield()` Combine wait with `withMainSerialExecutor` in
  `QuizViewModelSettingsPersistenceTests`. Drop the `+10` literal in
  `rerecordRestartsTimerWithBonus` — assert `> previous` instead.

**Exit:** all `+Timers.swift` paths exercised; streaming has ≥4 scenarios;
rerecord/resubmit branches covered; no `Task.yield()` waits remain.

### Phase 4 — Snapshot + ViewInspector (1–2 days)
Lock visual state of stable, distinctive screens. Text-tree strategy only —
no image snapshots.

- `Snapshots/ResultViewSnapshotTests.swift` — correct, wrong, partial,
  timeout.
- `Snapshots/QuestionViewSnapshotTests.swift` — open-ended, MCQ, image
  question, recording state, processing state.
- `Snapshots/PaywallViewSnapshotTests.swift` — locked + unlocked.
- `ComponentInspectorTests.swift` — ViewInspector for `HangsButton`,
  `MicButton`, `ProgressBarView` — label bindings + style modifiers.

**Exit:** four new files; iPhone 17 Pro sim only (no multi-device).

### Phase 5 — E2E and agent loop (1–2 days)
Lift `/regression` from manual fail-and-report to structured XCUITest the
agent can drive in parallel.

- Convert RS-01..RS-08 from `regression-scenarios.md` markdown into
  `XCUITest` methods in `HangsUITests/Regression/` with a Page Object per
  screen (`HomePage`, `QuestionPage`, `ResultPage`, `ConfirmationPage`).
  Each scenario → one test method.
- Add **RS-09**: paywall locked → purchase → unlocked, using `SKTestSession`.
- Update `/regression` skill: call `mcp__XcodeBuildMCP__test_sim` first
  (structured per-method JSON), HTTP-listener fallback only for scenarios
  XCUITest can't express.
- Add `.github/workflows/ios-ci.yml` running unit + UI tests on push to main
  (path-filtered to `apps/ios-app/**`).

**Exit:** `xcodebuild test -scheme Hangs-Local` passes; `/regression all` runs
via `test_sim`; ios-ci gate active.

### Out of scope (deliberate)

- Image-based snapshot tests (fragile under simulator updates).
- 100 % branch coverage (chase risk, not numbers).
- Performance benchmarks (`measure { }`) — premature; revisit when needed.
- Multi-device CI matrix — solo project, iPhone 17 Pro only.
- Mass migration of stub tests — leave until that file needs touching.

## Where the work lands

| Where | What changes |
|---|---|
| `apps/ios-app/Hangs/Hangs.xcodeproj` | SPM deps; `.storekit` in scheme |
| `apps/ios-app/Hangs/Hangs/Configuration/Hangs.storekit` (new) | StoreKit test config |
| `apps/ios-app/Hangs/HangsTests/Support/Fixtures.swift` (new) | Shared mock factories |
| `apps/ios-app/Hangs/HangsTests/StoreManagerTests.swift` (new) | Phase 2 |
| `apps/ios-app/Hangs/HangsTests/ElevenLabsSTTServiceTests.swift` (new) | Phase 2 |
| `apps/ios-app/Hangs/HangsTests/SilenceDetectionServiceTests.swift` (new) | Phase 2 |
| `apps/ios-app/Hangs/HangsTests/NetworkServiceTests.swift` (new) | Phase 2 |
| `apps/ios-app/Hangs/HangsTests/QuizViewModelStreamingTests.swift` (new) | Phase 3 |
| `apps/ios-app/Hangs/HangsTests/QuizViewModelTimerTests.swift` (new) | Phase 3 |
| `apps/ios-app/Hangs/HangsTests/Snapshots/*.swift` (new) | Phase 4 |
| `apps/ios-app/Hangs/HangsTests/ComponentInspectorTests.swift` (new) | Phase 4 |
| `apps/ios-app/Hangs/HangsUITests/Regression/*.swift` (new) | Phase 5 — RS-01..RS-09 as XCUITests |
| `.github/workflows/ios-ci.yml` (new) | Phase 5 — CI gate |
| `apps/ios-app/Hangs/Hangs/Views/*.swift` | Phase 1 — `.accessibilityIdentifier(_:)` |
| `apps/ios-app/Hangs/HangsTests/QuizViewModelTests.swift` | Phase 1 dedupe; phase 3 split timer tests; drop magic-number assert |
| `apps/ios-app/Hangs/HangsTests/AudioServiceTests.swift` | Phase 1 — delete `RecordingValidationTests`, rename `MockAudioServiceTests` |
| `apps/ios-app/Hangs/HangsTests/HangsTests.swift` | Phase 1 — delete |
| `docs/testing/regression-scenarios.md` | Phase 5 — link RS-NN to XCUITest method id |
| `.claude/skills/regression/SKILL.md` | Phase 5 — `test_sim` first, listener fallback |

## Risks + open questions

- **`SKTestSession` reliability on Xcode 26.3**: docs are sparse. Fallback:
  `StoreKitProtocol` + mock; manual TestFlight verification.
- **Snapshot drift across macOS upgrades**: text-dump strategy mitigates but
  doesn't eliminate. Commit baselines, re-record on intentional changes.
- **CI minutes**: unit + UI on every push could burn budget. Plan B: gate UI
  to PRs / nightly only.
- **Phase 5 depends on phase 1 a11y identifiers** — if phase 1 is incomplete,
  phase 5 stalls.

## Decisions captured (2026-05-06)

Decisions and the executable task breakdown live in the handoff doc:
**[issue-31-handoff.md](issue-31-handoff.md)**.

Summary:
1. **Granularity** — many small atomic tasks; each one delegated to a
   `model: sonnet` subagent so the main context stays clean.
2. **CI** — unit + snapshot tests on every push to main; UI/E2E manual.
3. **Snapshot vs XCUITest** — both, with clear roles. XCUITest = primary for
   state/flows. Snapshot = layout-distinctive stable screens only
   (`ResultView` answer cards, `PaywallView`).
4. **Mocks** — moved to test target. Production target stops carrying
   `Mock*Service` types; SwiftUI previews use inline preview-specific stubs.
5. **Scope** — phases 1–4 in this issue. Phase 5 (E2E refit + ios-ci +
   RS-NN as XCUITest) becomes **issue #32** opened after phase 4 lands.
