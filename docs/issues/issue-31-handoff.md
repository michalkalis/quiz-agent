# Issue 31 — handoff for next session

**Strategy:** [issue-31-ios-test-hardening.md](issue-31-ios-test-hardening.md)
**Status:** ready-for-agent · start at Phase 1 / Task 1.1
**Last updated:** 2026-05-06 (revised after audit — see "Corrections")

---

## Corrections made on 2026-05-06

The earlier draft had one **critical** flaw and several inaccuracies. The
task list below is the corrected version. Read this before starting.

### CRITICAL — Task 1.3 rewritten ("move mocks to test target" was unsafe)

The original Task 1.3 said: move `Mock*Service` types out of the production
target into `HangsTests/Mocks/`. That **breaks the production target's
debug build** because mocks are used at runtime by the app itself, not just
by previews:

- `Hangs/Utilities/AppState.swift:23-36` — under `--ui-test`, `init()`
  instantiates `MockNetworkService`, `MockAudioService`,
  `MockPersistenceStore`, `MockElevenLabsSTTService` for the running app.
- `Hangs/Utilities/UITestSupport.swift:40-55` — wires the same mocks and
  retains a `mockSTT` reference so the HTTP listener on `127.0.0.1:9999`
  can inject `STTEvent`s into the live app.
- `Hangs/ViewModels/QuizViewModel.swift:1010-1024` — `preview` /
  `previewWithEvaluation` static helpers are referenced by 6 view files
  (`HomeView`, `QuestionView`, `ResultView`, `MinimizedQuizView`,
  `AudioDevicePickerView`, `CompletionView`).
- `HangsTests` is a separate test bundle, not linked into the app binary —
  UI tests run against the actual app at `--ui-test`, which needs the
  mocks in-process.

**Corrected approach:** keep mocks in the production target under `#if
DEBUG`. Reorganize them into `Hangs/Services/Mocks/*.swift` for cleanliness
(one file per mock), but leave the `#if DEBUG` gate in place. This delivers
the "production binary doesn't ship test code" benefit without breaking
the UI-test seam.

### Other corrections

1. **Task 1.4 undercount.** The original plan listed 4 duplicated
   `makeViewModel` blocks (lines 290, 597, 1076, 1312). There are
   actually **~10 duplicated blocks** in `QuizViewModelTests.swift`:
   91, 290, 483, 597, 759, 802, 857, 924, 1076, 1178, 1312. Dedupe scope
   is roughly 2× the original estimate (~400 lines, not ~200).

2. **`ios-ci.yml` already exists** at `.github/workflows/ios-ci.yml`.
   Phase 5 should **extend** it (add UI-test job, snapshot baseline cache,
   StoreKit config), not "add" it.

3. **Simulator destination mismatch.** Existing `ios-ci.yml` uses
   `iPhone 16 Pro` on `macos-15`. CLAUDE.md and the plan use
   `iPhone 17 Pro`. Pick one and align both. Local development uses
   iPhone 17 Pro; CI may not have it on macos-15. If keeping iPhone 17
   Pro everywhere, bump the CI runner to a label that has it (or pin to
   `OS=latest`-equivalent).

4. **StoreKit config wiring (Task 1.2).** Adding the `.storekit` to the
   `Hangs-Local` scheme's *Run* action is **not enough** for unit tests —
   `SKTestSession` either reads it from the *Test* action of the test
   scheme, or you construct `SKTestSession(configurationFile:)` directly
   in test setup. Prefer the explicit constructor — it doesn't depend on
   scheme state and works in CI.

5. **No `Hangs/Configuration/` directory exists yet** — Task 1.2 must
   create it.

6. **Off-by-one line refs in Task 1.3 (now-superseded):** correct
   line numbers are `NetworkService.swift:664`, `AudioService.swift:898`,
   `SilenceDetectionService.swift:310`, `ElevenLabsSTTService.swift:249`,
   `PersistenceStore.swift:277`.

7. **Snapshot strategy nuance.** `swift-snapshot-testing` ships
   `.image` and `.dump` (Mirror-based) strategies for SwiftUI; there is no
   built-in "accessibility-tree" strategy. We will use `.dump` (text
   diff). The "text-tree" framing in the strategy doc maps to `.dump` in
   library terms.

---

## Decisions captured

### 1. Granularity — many small tasks, sonnet subagents

The 4 phases below split into **18 atomic tasks**. Each is sized for one
sonnet subagent invocation (~1–2 hours). Main context orchestrates: spawn
a `model: sonnet` subagent per task, validate the build, commit, move on.

See memory `feedback_subagent_model_routing` — always pass explicit
`model: sonnet` to delegated work.

### 2. CI scope — unit on every push, UI manual for now

`ios-ci.yml` (already in repo) currently runs unit tests on every push to
`main`. Phase 4 adds snapshot tests to the same job. UI/E2E (XCUITest,
`/regression` skill) stays manual until cost is understood; UI-test job
is opened in issue #32 (Phase 5).

### 3. Snapshot tests vs XCUITest — both, with clear roles

| | Snapshot tests | XCUITest |
|---|---|---|
| **What it does** | Renders a SwiftUI view, diffs against stored baseline. | Boots simulator, drives the app like a user, asserts on `accessibilityIdentifier` queries. |
| **Speed** | Fast (~50 ms, no simulator boot). | Slow (~30 s per test). |
| **One test = ?** | "This view renders the same as last approved." | "User can complete this flow and reach expected state." |
| **Catches** | Visual / layout regressions. | Behavioural regressions, state-machine bugs. |
| **Tool** | `swift-snapshot-testing` (`.dump` strategy) | `XCUIApplication` |

**Split for Hangs:**
- **XCUITest** = primary safety net for state correctness + flows. Lives
  in `HangsUITests/Regression/` as RS-01..RS-09 (Phase 5, issue #32).
- **Snapshot tests** = lock down layout-distinctive screens that change
  rarely: `ResultView` answer-card variants, `PaywallView` (locked /
  unlocked).
- **Skip** snapshots for `QuestionView` (too dynamic).
- Use `.dump` (text-mirror) snapshot strategy — avoids fragility on macOS
  / simulator updates.

### 4. Mocks — reorganize, do NOT move out of production target

Move `MockNetworkService`, `MockAudioService`, `MockPersistenceStore`,
`MockSilenceDetectionService`, `MockElevenLabsSTTService` from inline
`#if DEBUG` blocks at the bottom of each `Hangs/Services/*.swift` into
**dedicated files** under `Hangs/Services/Mocks/Mock*Service.swift`. Keep
the `#if DEBUG` gate. Production target binary still excludes them in
release.

**Why:** organization improves (mocks easier to find, easier to grow
without bloating the live service file), without breaking
`AppState`/`UITestSupport`/`QuizViewModel.preview` callers.

### 5. Scope — phases 1–4 here, phase 5 = issue #32

Phases 1–4 in this issue. Phase 5 (XCUITest conversion of RS-01..RS-09 +
paywall RS-09 + `/regression` `test_sim` refit + extending `ios-ci.yml`
with UI job) becomes **issue #32 — iOS E2E + agent regression refit**,
opened once Phase 4 lands.

**Effort estimate:** phases 1–4 ≈ 6–8 working days. Phase 5 ≈ 2–3 days.

---

## Task breakdown — 18 atomic tasks

Each task is a self-contained PR-sized unit. Pass `model: sonnet`. After
each task, main context runs `xcodebuild build -scheme Hangs-Local
-destination 'platform=iOS Simulator,name=iPhone 17 Pro'`, commits if
green, ticks the box.

### Phase 1 — Foundation (5 tasks)

- [x] **1.1** Add test-target SPM deps (`swift-concurrency-extras`,
  `swift-snapshot-testing`, `ViewInspector`). HangsTests target only —
  not the production target. *(cb00cca)*
- [x] **1.2** Create `Hangs/Configuration/Hangs.storekit` with the
  `com.carquiz.unlimited` non-consumable (id from `StoreManager.swift:15`).
  Wire it to the `Hangs-Local` scheme's **Run AND Test** actions. In
  test setup also support `SKTestSession(configurationFile:)` lookup so
  CI doesn't depend on scheme XML. *(a06b79b — Hangs.storekit added to
  HangsTests bundle via PBXFileSystemSynchronizedBuildFileExceptionSet
  to keep prod app clean.)*
- [x] **1.3** *(rewritten — c08987a)* Reorganize mocks into
  `Hangs/Services/Mocks/Mock{Network,Audio,Persistence,SilenceDetection,ElevenLabsSTT}Service.swift`,
  one per file. **Keep the `#if DEBUG` gate.** Do not move to
  `HangsTests/` — `AppState`/`UITestSupport`/`QuizViewModel.preview`
  depend on them at runtime in DEBUG builds. Source lines to relocate:
  `NetworkService.swift:662-…`, `AudioService.swift:896-…`,
  `SilenceDetectionService.swift:308-…`,
  `ElevenLabsSTTService.swift:248-…`, `PersistenceStore.swift:274-…`.
- [x] **1.4** *(ee59ab0)* Create `HangsTests/Support/Fixtures.swift` with
  `makeFullMockNetwork(...)`, `makeQuizSession(...)`, `makeQuestion(...)`,
  `makeQuizSettings(...)`. Replace **all ~10 duplicated `makeViewModel`
  blocks** in `QuizViewModelTests.swift` (lines 91, 290, 483, 597, 759,
  802, 857, 924, 1076, 1178, 1312) with factory calls. All tests still
  pass. Expect ~400 lines removed. *(Actual: 10 dupes — handoff
  miscounted line 857; -180 lines, 106 tests still green.)*
- [x] **1.5** Add `.accessibilityIdentifier(_:)` (kebab-case) to every
  interactive element in `HomeView`, `QuestionView`, `ResultView`,
  `AnswerConfirmationView`, `SettingsView`, `PaywallView`. Delete
  `HangsTests/HangsTests.swift` (empty `@Test func example` stub) and the
  `RecordingValidationTests` struct in `AudioServiceTests.swift:124`.
  Rename `MockAudioServiceTests` (`AudioServiceTests.swift:46`) →
  `MockAudioServiceContractTests`. *(QuestionView + AnswerConfirmationView
  were already fully annotated; +20 identifiers added across the other 4.
  103 tests passing — was 106, dropped 3 dead stubs.)*

### Phase 2 — Critical paths (5 tasks)

- [ ] **2.1** `HangsTests/StoreManagerTests.swift` (new) using
  `SKTestSession(configurationFile:)`: load products, purchase success,
  purchase cancel, purchase pending, transaction observer flips
  `isPurchased`, restore. **Risk:** if `SKTestSession` is flaky on Xcode
  26.3, fall back to a `StoreKitProtocol` extraction + mock.
- [ ] **2.2** `HangsTests/ElevenLabsSTTServiceTests.swift` (new):
  `handleMessage` parser tests with canned WebSocket JSON
  (`partial_transcript`, `committed_transcript`, `session_started`,
  `error`). URL construction asserts (VAD config, query params, language)
  using values from `Config.swift:117-134`.
- [ ] **2.3** `HangsTests/SilenceDetectionServiceTests.swift` (new):
  three-state machine `idle → speechActive → silenceAccumulating → emit`;
  threshold boundary cases (1.4 s, 1.5 s, 1.6 s). Gate with `@available(iOS
  26, *)` to mirror the production type.
- [ ] **2.4** `HangsTests/NetworkServiceTests.swift` (new), `URLProtocol`-
  stubbed: `NetworkError.dailyLimitReached` decoded from 429 +
  `DailyLimitErrorWrapper`; `downloadAudio` Content-Length mismatch
  raises `NetworkError.audioIntegrity`; happy paths for `extendSession`,
  `rateQuestion`, `flagQuestion`, `getUsage`, `setPremium`.
- [ ] **2.5** Extend `HangsTests/PersistenceStoreTests.swift`: `QuizStats`
  save/load round-trip + corruption fallback. Clean up orphaned
  UUID-named `UserDefaults` suites in `tearDown`.

### Phase 3 — Voice + timer pipeline (5 tasks)

- [ ] **3.1** `HangsTests/QuizViewModelStreamingTests.swift` (new), uses
  `withMainSerialExecutor`: `startStreamingRecording` happy path, partial
  transcript updates, committed-transcript transitions to `processing`,
  error returns to `askingQuestion`.
- [ ] **3.2** Split `QuizViewModelAnswerTimerTests` out into
  `HangsTests/QuizViewModelTimerTests.swift`. Add coverage for
  `startAutoAdvance` (cancel-on-mic-tap), `startAutoStopRecordingTimer`
  15 s safety, `startThinkingTimeCountdown` cancellation on early submit,
  and `handleBargeIn` (cancels TTS + transitions to `recording`).
- [ ] **3.3** Add `resubmitAnswer` text-path tests to
  `QuizViewModelTests.swift`: `transcriptWasEdited=true` does not replay
  TTS, transitions to `showingResult`.
- [ ] **3.4** Add tests for: exclusion-list wiring (`startNewQuiz` calls
  `getExclusionList()` and forwards IDs to
  `startQuiz(excludedQuestionIds:)`), and `QuizSettings` backward-compat
  decoder (legacy JSON missing `thinkingTime`, `autoConfirmEnabled`,
  `showConfirmSheet`, `isMuted`, `ageAppropriate`).
- [ ] **3.5** Replace `Task.yield()` Combine wait at
  `QuizViewModelTests.swift:946` with `withMainSerialExecutor`. Drop the
  literal `+10` constant in `rerecordRestartsTimerWithBonus` (line 905);
  assert `> previous` instead.

### Phase 4 — Snapshot + ViewInspector (3 tasks)

- [ ] **4.1** `HangsTests/Snapshots/ResultViewSnapshotTests.swift` (new)
  using `.dump` (text-mirror) strategy: correct, wrong, partial-credit,
  timeout variants. Baselines committed; iPhone 17 Pro sim only.
- [ ] **4.2** `HangsTests/Snapshots/PaywallViewSnapshotTests.swift` (new):
  locked + unlocked. Same `.dump` strategy.
- [ ] **4.3** `HangsTests/ComponentInspectorTests.swift` (new) using
  `ViewInspector` (`@MainActor` tests required under Swift 6 strict
  concurrency): `HangsButton` (label binding, style modifier),
  `MicButton` (state-driven icon + colour), `ProgressBarView`
  (progress-fraction binding).

### Phase 5 — deferred to issue #32

When phase 4 lands, open **issue #32 — iOS E2E + agent regression refit**
covering: RS-01..RS-08 → XCUITest, RS-09 paywall flow, `/regression`
skill switch to `test_sim`, **extension** of existing `ios-ci.yml` with a
UI-test job (and snapshot-baseline cache), Page Object classes
(`HomePage`, `QuestionPage`, `ResultPage`, `ConfirmationPage`).

Resolve the `iPhone 16 Pro` (CI) vs `iPhone 17 Pro` (local) destination
mismatch as part of #32.

---

## Subagent prompt template

For each task above, delegate with this skeleton (`model: sonnet`):

```
Implement Task N.M from docs/issues/issue-31-handoff.md.

Goal: <one-sentence task purpose>
Files in scope: <list>
Acceptance: <verifiable criterion — tests pass, build clean, etc.>

Context for fresh session:
- Project: Quiz Agent monorepo, iOS app at apps/ios-app/Hangs
- Swift 6, iOS 18+, Swift Testing for new unit tests
- Read docs/issues/issue-31-handoff.md for the decisions; this is task
  N.M from that file
- Follow .claude/rules/ios.md
- Mocks remain under #if DEBUG in Hangs/Services/Mocks/ (after Task 1.3);
  fixtures in HangsTests/Support/Fixtures.swift (after Task 1.4)

Constraints:
- Test infrastructure / coverage only — do NOT change production behavior
- Run `cd apps/ios-app/Hangs && xcodebuild build -scheme Hangs-Local
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` after
  changes; report failures
- If you hit unexpected issues, STOP and report — don't expand scope
- Keep new test files under 300 lines; split if needed
```

---

## How to start the next session

1. **Read this file**, especially the "Corrections" section.
2. **Run** `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local
   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` to confirm
   the baseline is green. If anything is red, fix that first.
3. **Find the first unchecked box** in "Task breakdown" (start: Task 1.1).
4. **Spawn a subagent** with the prompt template, model `sonnet`, fill in
   task specifics.
5. **After subagent reports back:** verify with `xcodebuild build`, run
   the relevant tests, commit (`test(ios): <what>`), tick the box, next.
6. **At end of phase:** run full `xcodebuild test -scheme Hangs-Local`,
   confirm green, commit, optionally pause for review before next phase.

---

## Status log

- 2026-05-06 — Strategy + handoff drafted.
- 2026-05-06 — Audit pass: critical Task 1.3 fix + 6 lesser corrections;
  task list rewritten. Awaiting first agent run.
