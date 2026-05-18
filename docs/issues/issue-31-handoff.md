# Issue 31 — handoff for next session

**Strategy:** [issue-31-ios-test-hardening.md](issue-31-ios-test-hardening.md)
**Status:** ready-for-agent · Phase 1 done · start at **Task 1.6** (new — see below)
**Last updated:** 2026-05-07 (execution plan added)

---

## Execution plan — 2026-05-07

Konkrétne poradie a orchestrácia zostávajúcich 15 taskov (Phase 1 finish +
Phase 2/3/4). Každý task = jeden `model: sonnet` subagent, prompt template
nižšie v dokumente. Hlavný kontext orchestruje, validuje build, commituje.

### Krok 0 — baseline sanity check

```
cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Musí prejsť 103 testov. Ak je niečo red, opraviť pred Task 1.6.

### Krok 1 — Phase 1 finish (Tasks 1.6 + 1.7, paralelne)

Single message s 2× `Agent` call:

- **1.6** production seams (7 zmien `private`→`func` + clock/URLSession
  injection, bez behaviour-change). Commit prefix `refactor(ios):`.
- **1.7** CI alignment (drop `| xcpretty || true`, `set -o pipefail`, bump
  Xcode 16.2→26.3, iPhone 16 Pro→17 Pro, smoke-test red flip). Commit
  prefix `chore(ci):`.

Po návrate oboch: `xcodebuild build`, dva commity, tick boxy.
**→ natural pause point pre review pred Phase 2.**

### Krok 2 — Phase 2 critical paths (risk-prioritized)

Task 2.1 ide samostatne (architectural change). Tasks 2.2–2.5 môžu ísť
paralelne (4× sonnet v jednej správe), ale sekvenčne je ľahšie reviewovať.

| # | Task | Závisí na | Poznámka |
|---|---|---|---|
| 1 | **2.1** StoreManager — voľba **B** (PurchaseService protocol) | — | Architectural; sleduje pattern `NetworkServiceProtocol` |
| 2 | **2.4** NetworkService URLProtocol stubs | 1.6 (URLSession inject) | |
| 3 | **2.2** ElevenLabsSTT handleMessage | 1.6 (handleMessage internal + buildWebSocketURL) | |
| 4 | **2.3** SilenceDetection 3-state machine | 1.6 (`now` clock inject) | Threshold boundary 1.4/1.5/1.6 s |
| 5 | **2.5** PersistenceStore QuizStats round-trip | — | Najnižší risk |

Po každom: build green → `test(ios): ...` commit → tick box.
Exit: 5 nových test files green, CI green, všetkých 7 seamov z 1.6
overených non-breaking.

### Krok 3 — Phase 3 voice + timer (sekvenčne)

- **3.1** `QuizViewModelStreamingTests.swift` — confirmation OUTSIDE,
  `withMainSerialExecutor` INSIDE (audit A2-5)
- **3.2** `QuizViewModelTimerTests.swift` — split z 1188-line file
- **3.3** `QuizViewModelResubmitTests.swift` — **nový súbor** (file-size limit)
- **3.4** `QuizViewModelSettingsCompatTests.swift` — **nový súbor**
- **3.5** Cleanup `Task.yield()` + magic `+10` literal

3.1 a 3.2 sú najťažšie (Swift Testing concurrency); subagent prompt musí
explicitne uvádzať A2-5.

### Krok 4 — Phase 4 ViewInspector + targeted snapshot

- **4.1** `ResultViewInspectorTests.swift` — **ViewInspector** (NIE `.dump`),
  state-driven assertions, `.implicitAnyView()` chain (A2-7)
- **4.2** `PaywallViewSnapshotTests.swift` — `.dump` (locked vs unlocked
  je štrukturálne odlišné)
- **4.3** `ComponentInspectorTests.swift` — `HangsButton`, `MicButton`,
  `ProgressBarView`, `.implicitAnyView()` (A2-7)

### Krok 5 — close-out

Po Phase 4: full test run, commit, otvoriť **issue #32** (E2E refit, RS-NN
ako XCUITest, snapshot-baseline cache, `/regression` skill switch).

### Decisions captured pre tento execution plan

1. **Task 2.1 → voľba B** (Protocol-wrap StoreKit). Plán A (iOS 18 test plan)
   by ťa zaviazal držať dva simulátory v CI; B sleduje existujúci pattern
   protocol-wrapped servisov.
2. **1.6 + 1.7 paralelne** — sú nezávislé, jeden round subagentov.
3. **Phase 2 tasky 2.2–2.5 sekvenčne** — pre solo project je lepší review
   tempo než paralelný throughput. (Možno zmeniť na paralelné, ak sa
   ukáže, že main context to zvláda.)
4. **Phase 3 vždy sekvenčne** — concurrency nuances vyžadujú sústredenie
   pri review.

### Effort estimate

| Fáza | Tasky | Čas |
|---|---|---|
| Phase 1 finish (1.6 + 1.7) | 2 | ~0.5 dňa |
| Phase 2 | 5 | 2–3 dni |
| Phase 3 | 5 | 2–3 dni |
| Phase 4 | 3 | 1–2 dni |
| **Spolu** | **15** | **6–8 dní** |

### Per-task workflow (orchestration loop)

1. Spawn `Agent(subagent_type=general-purpose, model=sonnet)` s prompt
   template (sekcia "Subagent prompt template" nižšie).
2. Subagent reportne back → `xcodebuild build -scheme Hangs-Local
   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
3. Green → relevantné testy → commit (`test(ios):` / `refactor(ios):` /
   `chore(ci):`) → tick box v tomto dokumente.
4. Red → prečítať output, rozhodnúť: fix v main contexte alebo respawn
   subagent s konkrétnou hint.
5. Na konci fázy: full `xcodebuild test`, optional pause pre review.

---

## Audit pass 2 — 2026-05-07 (research-backed)

After Phase 1 landed (1.1–1.5), a second audit examined the production code
that Phase 2/3 will touch and researched the technical foundations
(`SKTestSession` on iOS 26, `swift-concurrency-extras` 1.3.2, ViewInspector
0.10.3, snapshot strategies). Three categories of issue surfaced.

### A2-1 — `StoreManagerTests.swift` hides a confirmed Apple regression

The Risk-Materialized note in Task 2.1 says: "fix path is in-app-payments
entitlement + scheme without TSAN." **That is wrong.** Research:

- `SKInternalErrorDomain Code=3` on iOS 26 sim is a **confirmed Apple-side
  regression** (Flutter #184678; Apple Developer Forum thread/808030 +
  storekittest tag, May 2026). No public report confirms entitlement or
  TSAN-off as a fix.
- `com.apple.developer.in-app-payments` is for production device-distribution
  signing. SKTestSession runs offline without entitlements per Apple's
  [Setting up StoreKit Testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode/).
  Adding the entitlement will not fix the simulator daemon.
- 6 of 9 tests guard with `storeKitAvailable() else { return }` — under iOS
  26 sim those guards **always trigger**, so tests pass with zero assertions.
  Of the 3 unguarded: 1 is the env probe, 2 are intentionally daemon-free
  (`purchaseCancelLeavesFalse`, `checkPurchaseStatusFalseWhenClean`) and
  contain real assertions. CI is falsely green on the 6 guarded paths;
  revenue path is untested. **Worse than no test.**

**Required action — pick one** (A) or (B) below; A is short-term, B is the
right architectural answer:

- **(A) iOS 18.x test plan.** Add `HangsTests-StoreKit.xctestplan` that
  targets `iPhone 16, OS=18.4` for SKTestSession-dependent tests. Ostatné
  testy zostávajú na iPhone 17 Pro / iOS 26. CI runs both plans. SKTestSession
  is stable on iOS 18.x.
- **(B) Protocol-wrap StoreKit (preferred).** `protocol PurchaseService`
  → `LivePurchaseService` (delegates to `Product.products(for:)` /
  `Transaction.currentEntitlements` / `purchase()`) + `MockPurchaseService`.
  `StoreManager` injects the protocol. Unit tests of `StoreManager` logic
  become daemon-free. Manual TestFlight verification covers "we are actually
  talking to StoreKit."

Either way: **rewrite the comment header in `StoreManagerTests.swift:8-29`**
to reflect the Apple regression (not the mistaken entitlement claim), and
re-tag silently-skipping tests with `@Test(.disabled("..."))` so they are
visible in the report instead of falsely green.

### A2-2 — Phase 2 / 3 tasks need production seams not yet listed

A code audit of the methods Phase 2 + 3 want to test found that most are
`private` or have non-injectable dependencies. Each is a one-line change,
no behaviour change — but the plan must list them or sub-agents will either
get blocked or expand scope. **Bundled into new Task 1.6 below.**

| For task | File:Line | Change |
|---|---|---|
| 2.2 | `ElevenLabsSTTService.swift:179` | `private func handleMessage` → `func` (internal) |
| 2.2 | `ElevenLabsSTTService.swift:56-72` | Extract `static func buildWebSocketURL(token:languageCode:) throws -> URL`; `connect()` calls it. URL construction asserted in isolation, no real WebSocket. |
| 2.3 | `SilenceDetectionService.swift:244` | `private func handleSpeechDetectorResult` → `func` (internal) |
| 2.3 | `SilenceDetectionService.swift:75-83` + `:268,271` | Inject `now: @escaping @MainActor () -> Date = { Date() }` v init; replace `Date()` with `self.now()`. Without this the **1.4 / 1.5 / 1.6 s boundary cannot be tested deterministically**. |
| 2.4 | `NetworkService.swift:37-47` | Add `session: URLSession? = nil` to init; use injected session if provided. URLProtocol stubs are per-session-configuration — non-injectable session = non-stubbable. |
| 3.1 | `QuizViewModel+Recording.swift:70` | `private func startStreamingRecording` → `func` (internal) |
| 3.2 | `QuizViewModel+Audio.swift:40` | `private func handleBargeIn` → `func` (internal) |

Tasks 3.3 (`resubmitAnswer`), 3.4 (`startNewQuiz`/`getExclusionList` /
`QuizSettings` decoder) are already `internal` — no seam needed.

### A2-3 — Phase 4 snapshot strategy is mis-specified for `ResultView`

Plan says: `.dump` strategy locks 4 `ResultView` variants (correct, wrong,
partial, timeout). Research (`swift-snapshot-testing` 1.19.2): `.dump`
reflects the **View struct via `Mirror`**, NOT runtime state from
`@StateObject` / `@ObservedObject`. The 4 ResultView variants differ by
runtime state (`evaluation.isCorrect`, partial credit, etc.), not
structurally. `.dump` baselines will be near-identical. False coverage.

**Reorganize Phase 4:**
- **4.1** — use **ViewInspector** (not snapshot) for `ResultView` state cases:
  assert green-check icon + "Správne" label when `evaluation.isCorrect`,
  red-X + "Nesprávne" when not, partial-credit badge for partial, timeout
  state for `nil`. ViewInspector reads `@StateObject` runtime state.
- **4.2** — keep `.dump` for `PaywallView` (locked vs unlocked **does** differ
  structurally — different button stack + lock icon).
- **4.3** — `ComponentInspectorTests` as planned (`HangsButton`, `MicButton`,
  `ProgressBarView`).

If pixel-accurate ResultView locking is wanted, use `.image` strategy with
iPhone 17 Pro pinned, and accept OS-upgrade re-record (commit baselines).
But prefer ViewInspector — state-driven assertions are more meaningful and
don't drift on cosmetic changes.

### A2-4 — `ios-ci.yml` issues that will bite Phase 4

`.github/workflows/ios-ci.yml`:

- Line 47-48: `| xcpretty || true` **masks test failures**. CI will be
  green even with red tests. Phase 4 snapshot drift would never trip CI.
  **Fix:** drop `|| true`, add `set -o pipefail`.
- Xcode 16.2 + iPhone 16 Pro (CI) vs Xcode 26.3 + iPhone 17 Pro (local).
  Beyond destination mismatch: snapshot baselines (Phase 4) **will not
  match across these Xcode versions** (Liquid Glass on iOS 26, layout
  differences). Either bump CI to `Xcode_26.3.app` + iPhone 17 Pro, or pin
  Phase 4 snapshot job to one specific environment.

**Bundled into new Task 1.7 below — must land before Phase 4.**

### A2-5 — Swift Testing + `withMainSerialExecutor` nesting (Phase 3)

`swift-concurrency-extras` issue #27: under Swift Testing + Swift 6 strict
concurrency, nesting `await confirmation { ... }` **inside**
`withMainSerialExecutor` emits a "sending main-actor-isolated value" warning.
**Workaround:** confirmation outside, executor inside.

Phase 3.1 streaming tests will likely use `confirmation` for `STTEvent`
assertions. Sub-agent prompt template should include:

```swift
// Correct under Swift Testing + Swift 6:
await confirmation { confirmed in
    await withMainSerialExecutor {
        // … drive viewModel; await confirmed() inside callbacks
    }
}
// NOT: withMainSerialExecutor { await confirmation { ... } }
```

### A2-6 — File-size limit for Tasks 3.3 + 3.4

`QuizViewModelTests.swift` is currently 1188 lines (memory
`feedback_file_size_limit`: keep under ~300). Tasks 3.3 (resubmit text path)
and 3.4 (exclusion-list + legacy decoder) should land in **new files**:

- `QuizViewModelResubmitTests.swift` — Task 3.3
- `QuizViewModelSettingsCompatTests.swift` — Task 3.4

A separate cleanup task (post-Phase 3) should split the existing 1188-line
file. Out of scope for this issue but flag for issue #34 if relevant.

### A2-7 — ViewInspector + Swift 6 implicit `AnyView`

ViewInspector 0.10.3 documents that Swift 6 / Xcode 16+ inserts implicit
`AnyView` wrappers in the view hierarchy. Sub-agents writing 4.1 and 4.3
must use `.implicitAnyView()` in assertions or chains will fail with
"InspectorError: missing AnyView wrapper". Add to Task 4.1 + 4.3 description.

### A2-8 — Drop "test/code ratio ≥ 25%" exit criterion

Per memory `feedback_root_cause_debugging`: chase risk, not numbers. Replace
Phase 2 exit criterion with: "five new test files green; CI green; all
seams from Task 1.6 verified non-breaking."

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
- [x] **1.6** *(added 2026-05-07 — see audit A2-2)* Production test seams.
  No behaviour change. Commit prefix `refactor(ios):`. Bundle all 7 changes
  in one PR-sized task so Phase 2/3 sub-agents have a clean breakpoint.
  - `ElevenLabsSTTService.swift:179` — `private func handleMessage` → `func`
  - `ElevenLabsSTTService.swift:56-72` — extract
    `static func buildWebSocketURL(token:languageCode:) throws -> URL`;
    `connect()` calls it
  - `SilenceDetectionService.swift:244` — `private func
    handleSpeechDetectorResult` → `func`
  - `SilenceDetectionService.swift:75-83`+`:268,271` — inject
    `now: @escaping @MainActor () -> Date = { Date() }`; replace `Date()`
    with `self.now()`
  - `NetworkService.swift:37-47` — add `session: URLSession? = nil`
    parameter to `init`; use injected session if provided
  - `QuizViewModel+Recording.swift:70` — `private func
    startStreamingRecording` → `func`
  - `QuizViewModel+Audio.swift:40` — `private func handleBargeIn` → `func`

  **Acceptance:** `xcodebuild build -scheme Hangs-Local` green, all 103
  current tests still pass, no public API surface changes.

- [x] **1.7** *(added 2026-05-07 — see audit A2-4)* CI alignment.
  `.github/workflows/ios-ci.yml`:
  - Drop `| xcpretty || true`; add `set -o pipefail` to the test step so
    failures surface
  - Bump `Xcode_16.2.app` → `Xcode_26.3.app` and destination to
    `iPhone 17 Pro,OS=latest` to align with local + Phase 4 snapshot env.
    If `Xcode_26.3.app` not on `macos-15`, pin to the runner label that has
    it (likely `macos-26` or `macos-latest` once GH ships it).

  **Acceptance:** ios-ci green on push to main with the existing test
  suite; failing-test smoke test (introduce a deliberate `#expect(false)`
  in a temporary commit) actually flips CI red. Revert the smoke commit.

### Phase 2 — Critical paths (5 tasks)

- [x] **2.1** `HangsTests/StoreManagerTests.swift` — **rework required (see
  audit A2-1)**. *(2715984 — PurchaseService protocol + LivePurchaseService + MockPurchaseService; 12 daemon-free tests, 115 total green)* Current state: 9 tests, 264 lines. 6 of 9 silently skip
  under iOS 26 sim via `storeKitAvailable()` guard → CI is falsely green
  on revenue-critical code. The previously-claimed fix path (in-app-payments
  entitlement + TSAN-off) is **incorrect**: SKTestSession on iOS 26 sim is
  a confirmed Apple-side regression (Flutter #184678; Apple Developer
  Forum thread/808030 + storekittest tag, May 2026), and the entitlement
  is for production-device signing, not simulator unit tests.

  **Pick A or B (B preferred):**

  **(A) iOS 18 test plan (short-term).** Add
  `HangsTests-StoreKit.xctestplan` configured to run StoreKit-dependent
  tests on `iPhone 16, OS=18.4`. Other tests stay on iPhone 17 Pro / iOS 26.
  CI runs both plans. Tradeoff: keeps current SKTestSession code; pulls in
  an iOS 18 sim dependency.

  **(B) Protocol-wrap StoreKit (preferred).** Introduce
  `protocol PurchaseService` with methods covering `loadProduct()`,
  `purchase()`, `restore()`, `currentEntitlements()`. `LivePurchaseService`
  delegates to StoreKit 2 APIs (`Product.products(for:)`,
  `product.purchase()`, `Transaction.currentEntitlements`). `StoreManager`
  injects the protocol. Tests use `MockPurchaseService` — daemon-free,
  deterministic. Manual TestFlight verification covers "we are actually
  talking to StoreKit." This is the same pattern as
  `NetworkServiceProtocol` / `AudioServiceProtocol` already in this app.

  Either way:
  - **Rewrite `StoreManagerTests.swift:8-29` comment header** to reflect
    the Apple regression (drop the entitlement / TSAN claim).
  - Replace `guard await storeKitAvailable() else { return }` with
    `@Test(.disabled("SKTestSession daemon broken on iOS 26 sim — see
    Flutter #184678"))` so skipped tests appear as skipped, not green.
- [x] **2.2** `HangsTests/ElevenLabsSTTServiceTests.swift` (new):
  `handleMessage` parser tests with canned WebSocket JSON
  (`partial_transcript`, `committed_transcript`, `session_started`,
  `error`). URL construction asserts (VAD config, query params, language)
  using values from `Config.swift:117-134`.
- [x] **2.3** `HangsTests/SilenceDetectionServiceTests.swift` (new):
  three-state machine `idle → speechActive → silenceAccumulating → emit`;
  threshold boundary cases (1.4 s, 1.5 s, 1.6 s). Gate with `@available(iOS
  26, *)` to mirror the production type.
- [x] **2.4** `HangsTests/NetworkServiceTests.swift` (new), `URLProtocol`-
  stubbed: `NetworkError.dailyLimitReached` decoded from 429 +
  `DailyLimitErrorWrapper`; `downloadAudio` Content-Length mismatch
  raises `NetworkError.audioIntegrity`; happy paths for `extendSession`,
  `rateQuestion`, `flagQuestion`, `getUsage`, `setPremium`.
- [x] **2.5** Extend `HangsTests/PersistenceStoreTests.swift`: `QuizStats`
  save/load round-trip + corruption fallback. Clean up orphaned
  UUID-named `UserDefaults` suites — Swift Testing has no `tearDown`;
  use `struct` `init()`/`deinit` lifecycle (per-test instance) or wrap
  the suite content in a do-block that calls a cleanup closure on the
  way out.

### Phase 3 — Voice + timer pipeline (5 tasks)

- [x] **3.1** `HangsTests/QuizViewModelStreamingTests.swift` (new), uses
  `withMainSerialExecutor`: `startStreamingRecording` happy path, partial
  transcript updates, committed-transcript transitions to `processing`,
  error returns to `askingQuestion`.
  **Swift Testing nesting (audit A2-5):** when using
  `confirmation { ... }` for `STTEvent` assertions, place `confirmation`
  on the outside, `withMainSerialExecutor` inside. The reverse triggers a
  Swift 6 sending-isolation warning. See `swift-concurrency-extras#27`.
  *(4 tests, 163 total green. Initial subagent attempt used fixed `Task.yield()`
  counts which couldn't pump events through `actor MockSTT` → AsyncStream →
  listener → `@MainActor` deterministically; replaced with a bounded
  `waitUntil(predicate:)` helper. `confirmation` wasn't actually needed —
  polling on `@Published` state under `withMainSerialExecutor` was simpler.)*
- [x] **3.2** Split `QuizViewModelAnswerTimerTests` out into
  `HangsTests/QuizViewModelTimerTests.swift`. Add coverage for
  `startAutoAdvance` (cancel-on-mic-tap), `startAutoStopRecordingTimer`
  15 s safety, `startThinkingTimeCountdown` cancellation on early submit,
  and `handleBargeIn` (cancels TTS + transitions to `recording`).
  *(14 tests, 172 total green. Auto-advance "cancel-on-mic-tap" framed as
  the realistic affordance — mic-tap from .showingResult is a no-op, so
  tested `pauseQuiz` cancels the .autoAdvance task and the `autoAdvanceEnabled`
  / `currentQuestionPaused` early-return guards. Auto-stop 15s safety
  asserted via `taskBag.contains(.autoStopRecording)` rather than waiting
  on real time. The +10s rerecord literal also dropped here per task 3.5
  hint — assertion is now `> previous` against `settings.answerTimeLimit`.)*
- [x] **3.3** *(file change per audit A2-6)* New file
  `HangsTests/QuizViewModelResubmitTests.swift`: `resubmitAnswer` text path
  (`transcriptWasEdited=true`) does not replay TTS, transitions to
  `showingResult`. Do NOT add to `QuizViewModelTests.swift` — that file is
  already 1188 lines (file-size memory).
  *(5 tests, 177 total green. Option A: added `capturedTextInputAudio` /
  `capturedTextInputInput` to `MockNetworkService` so the `audio:` arg can
  be asserted directly — same pattern as other `#if DEBUG` test seams. Tests
  cover: suppressAudio:true → audio:false; suppressAudio:false +
  audioMode!="off" → audio:true; suppressAudio:false + audioMode=="off" →
  audio:false (silent setting still respected); end-to-end
  `beginEditingTranscript()` → `confirmAnswer()` submits with audio:false
  and clears `transcriptWasEdited`; suppressAudio:true reaches
  `.showingResult`.)*
- [x] **3.4** *(file change per audit A2-6)* New file
  `HangsTests/QuizViewModelSettingsCompatTests.swift`: exclusion-list wiring
  (`startNewQuiz` calls `getExclusionList()` and forwards IDs to
  `startQuiz(excludedQuestionIds:)`), and `QuizSettings` backward-compat
  decoder (legacy JSON missing `thinkingTime`, `autoConfirmEnabled`,
  `showConfirmSheet`, `isMuted`, `ageAppropriate`).
  *(2e80d30 — 11 tests, 188 total green. 3 wiring + 8 decoder. Added
  `capturedStartQuizExcludedIds` capture property to `MockNetworkService`
  under `#if DEBUG`, mirroring the `capturedTextInputAudio` pattern from
  task 3.3. Decoder tests cover each defaulted key in isolation, all five
  missing simultaneously, unknown legacy keys silently ignored, and a
  required-key-missing negative case.)*
- [x] **3.5** Replace `Task.yield()` Combine wait at
  `QuizViewModelTests.swift:946` with `withMainSerialExecutor`. Drop the
  literal `+10` constant in `rerecordRestartsTimerWithBonus` (line 905);
  assert `> previous` instead.
  *(188 tests green. Wrapped each of the 3 `QuizViewModelSettingsPersistenceTests`
  cases in `await withMainSerialExecutor { ... }` and dropped all 5
  `Task.yield()` waits — Combine $settings.dropFirst().removeDuplicates().sink
  runs synchronously on the same main-actor turn under the serial executor, so
  no yield is needed at all. The `+10` literal was already removed in 3.2;
  3.5 reduced to the yield swap as the hint suggested.)*

### Phase 4 — ViewInspector + targeted snapshot (3 tasks)

*(reorganized 2026-05-07 per audit A2-3 — `.dump` is structural-only and
will not differentiate state-driven `ResultView` variants)*

- [x] **4.1** `HangsTests/ResultViewInspectorTests.swift` (new) using
  **ViewInspector** (not snapshot): assert that with an `evaluation` of
  each variant the rendered tree contains the expected affordances —
  correct → green-check icon + "Správne" label; wrong → red-X +
  "Nesprávne"; partial-credit → partial badge + score; timeout
  (`evaluation == nil`) → timeout copy + retry CTA. Use
  `.implicitAnyView()` chain step (audit A2-7 — Swift 6 inserts implicit
  `AnyView`). `@MainActor` on the suite.
  *(816539d — 4 tests, 192 total green. `find(text:)` breadth-first on
  ViewHosting-hosted view. Hero ("NAILED IT." / "CLOSE—BUT NO."), banner
  ("CORRECT" / "NOT QUITE"), SF Symbol icon (checkmark / xmark), footer
  button, and absence assertions for timeout all pass. answerCard/statsRow
  assertions (behind `showEvaluation @State` gate) are not reachable
  without `didAppear` refactor in ResultView — @State backing store in
  hosted context differs from re-inspected struct storage; model-level
  assertions (`resultEvaluation?.result`, `.points`) used as fallback for
  partial-credit and timeout cases.)*
- [x] **4.2** `HangsTests/Snapshots/PaywallViewSnapshotTests.swift` (new):
  locked + unlocked **only**. `.dump` strategy is appropriate here — the
  two states differ structurally (locked = lock icon + price + purchase
  button; unlocked = success state with different stack). iPhone 17 Pro
  sim, baselines committed.
  *(0d94225 + follow-up — 2 tests + 2 baselines. PaywallView has no real
  "unlocked" view; chosen variants are
  (A) `limitError` present + product loaded ($4.99) vs.
  (B) `limitError` nil + product nil (loading). Initially the `.dump`
  walked through `@ObservedObject → StoreManager → MockPurchaseService`
  into the `AsyncStream.Continuation` opaque internals, whose
  `continuations: N elements` count varied across runs depending on
  observer-registration timing — flaked in the full suite. Fix:
  `MockPurchaseService: CustomReflectable` returning empty children so
  Mirror walkers see the mock as opaque. Baselines re-recorded;
  deterministic.)*
- [x] **4.3** `HangsTests/ComponentInspectorTests.swift` (new) using
  `ViewInspector` (`@MainActor`, `.implicitAnyView()` per audit A2-7):
  `HangsButton` (label binding, style modifier), `MicButton` (state-driven
  icon + colour), `ProgressBarView` (progress-fraction binding).
  *(220 tests total green. Split into three files to honour the
  ~300-line file-size limit:
  `HangsButtonInspectorTests.swift` (189 lines — Primary/Secondary/Ghost,
  6+3+5 tests covering title, leading/trailing icon, action tap, loading
  ProgressView swap, no-icon absence), `MicButtonInspectorTests.swift`
  (129 lines — 3 states × (icon SF Symbol + accessibility label) +
  distinctness across states), `ProgressBarViewInspectorTests.swift`
  (99 lines — 0%/50%/100% percentage Text, custom title,
  `showPercentage: false` absence, GeometryReader structural presence).
  ViewHosting.host(view:) for inspection. Colour assertions for
  MicButton's gradient/shadow are skipped — those modifiers aren't
  exposed through ViewInspector — but the state-driven SF Symbol icon +
  accessibility label give equivalent coverage.)*

### Phase 4 — outcome

Phase 4 complete. 220 tests in 40 suites, all green. Coverage added:
- ResultView 4 state variants (ViewInspector, hero/banner/icon/footer)
- PaywallView 2 structurally-distinct variants (`.dump` snapshot, baselines
  committed)
- 5 reusable UI components (HangsPrimaryButton, HangsSecondaryButton,
  HangsGhostButton, MicButton, ProgressBarView)
- Test-stability fix: `MockPurchaseService: CustomReflectable` so any
  future `.dump`-based tests that transitively reach the mock get
  deterministic output.

Phase 5 follow-up moves to issue #32 (iOS E2E + agent regression refit).

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
- Test infrastructure / coverage only — do NOT change production behavior.
  EXCEPTION: Task 1.6 explicitly opens production seams (`private` → `func`
  + clock injection + `URLSession` injection); follow its checklist exactly
  and stop when those 7 changes are in.
- Run `cd apps/ios-app/Hangs && xcodebuild build -scheme Hangs-Local
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` after
  changes; report failures
- If you hit unexpected issues, STOP and report — don't expand scope
- Keep new test files under 300 lines; split if needed
- For Phase 3 streaming/timer tests: nest Swift Testing `confirmation` on
  the OUTSIDE, `withMainSerialExecutor` on the INSIDE (audit A2-5)
- For Phase 4 ViewInspector: chain `.implicitAnyView()` between view-tree
  steps under Swift 6 / Xcode 16+ (audit A2-7)
```

---

## How to start the next session

1. **Read this file**, especially the "Audit pass 2 — 2026-05-07" section
   (and the older "Corrections made on 2026-05-06" for context).
2. **Run** `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local
   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` to confirm
   the baseline is green. If anything is red, fix that first.
3. **Find the first unchecked box** in "Task breakdown" (next: Task 1.6).
4. **Spawn a subagent** with the prompt template, model `sonnet`, fill in
   task specifics.
5. **After subagent reports back:** verify with `xcodebuild build`, run
   the relevant tests, commit (`refactor(ios):` for 1.6/1.7, otherwise
   `test(ios): <what>`), tick the box, next.
6. **At end of phase:** run full `xcodebuild test -scheme Hangs-Local`,
   confirm green, commit, optionally pause for review before next phase.

---

## Status log

- 2026-05-06 — Strategy + handoff drafted.
- 2026-05-06 — Audit pass 1: critical Task 1.3 fix + 6 lesser corrections;
  task list rewritten.
- 2026-05-07 — Phase 1 (Tasks 1.1–1.5) complete. Audit pass 2: research
  (SKTestSession iOS 26 regression, swift-concurrency-extras 1.3.2,
  ViewInspector 0.10.3, snapshot strategies) surfaced 8 corrections (A2-1
  … A2-8). Task 2.1 reframed (current StoreManagerTests gives false
  coverage); new Task 1.6 (production seams) and 1.7 (CI alignment) added
  before Phase 2. Phase 4 reorganized — `ResultView` moves from `.dump`
  snapshots to ViewInspector. Phase 3 file-size split (3.3, 3.4 → new
  files). Sub-agent prompt updated with Swift Testing nesting + implicit
  AnyView notes.
- 2026-05-18 — XCUITest runtime blocker investigated. Added
  `Hangs-Local-UITests.xcscheme` with `enableThreadSanitizer = "NO"`
  (option B from prior handoff). **TSAN ruled out as the cause.** With
  TSAN=NO the same crash still fires on testRSStart launch:
  `*** Assertion failure in -[XCUIApplication init], XCUIApplication.m:113`
  `freed pointer was not the last allocation`. Reproduced on **both**
  `iPhone 17 Pro / iOS 26.3` and `iPhone 16 Pro / iOS 18.6` simulators
  with Xcode 26.2 — so it's also **not iOS 26.3-specific** as the prior
  handoff hypothesised. Setting `MallocNanoZone=0` as a launch env var
  did not change the outcome either. The crash happens inside Apple's
  `XCUIApplication.init` before our app launches; build-for-testing is
  green. **Real cause hypothesis (unverified):** `HangsUITests` target's
  pbxproj configs (`5090EC65`–`5090EC68`) are minimal — only
  `PRODUCT_NAME = HangsUITests`. They're missing `TEST_TARGET_NAME`,
  `PRODUCT_BUNDLE_IDENTIFIER`, `IPHONEOS_DEPLOYMENT_TARGET`, signing
  settings, and other UI-test-target essentials that `HangsTests` has.
  Next attempt: backfill those in pbxproj and re-run. Scheme kept (TSAN
  off is still semantically right for UI tests) but doesn't unblock yet.
