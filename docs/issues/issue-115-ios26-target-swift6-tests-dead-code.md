# Issue 115: Raise deployment target to iOS 26 + Swift 6 test targets + dead-code sweep

**Triage:** chore · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 items 5, 6. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 items 5, 6 + dimensions 5, 6, 8. Link, don't restate.

## Why

1. **Raise deployment target 18.0 → 26.0** (Top 10 item 5) — the entire availability surface is two `@available(iOS 26,*)` guards; there is **no legacy speech fallback**, so any sub-26 install silently loses VAD / barge-in / voice commands — an untested, product-degrading path shipped by omission. Raising deletes both guards, de-optionalizes `SilenceDetectionServiceProtocol` (~14 nil-branches removed), and guarantees SpeechAnalyzer everywhere.
2. **Unify test targets onto Swift 6 strict** (same change) — HangsTests/HangsUITests pin `SWIFT_VERSION = 5.0` and never include `Shared.xcconfig`, so test code compiles with neither Sendable checking nor MainActor-default while the app it exercises runs Swift 6 — the suite can pass on isolation assumptions the shipping app doesn't hold. Fold tests into Shared's settings.
3. **One dead-code sweep** (Top 10 item 6) — 13 dead pre-redesign Components (three name-colliding with the live `Hangs*` set — a standing edit-trap) + dead `LanguagePickerView` / `AudioRoutePickerWrapper` + two inspector test files that keep dead code green. Deleting shrinks the Swift-6 surface before it is raised and removes ambiguity for every future edit.

## Scope

**In:**
- **Target raise 18.0 → 26.0** — `Shared.xcconfig:42` + the 12 inline test-target entries (`project.pbxproj`); delete both `@available(iOS 26,*)` guards (`SilenceDetectionService.swift:89`, `AppState.swift:81`); de-optionalize `SilenceDetectionServiceProtocol` — ~14 nil-branch sites + property/init plumbing (see Research for the site list).
- **Test targets → Swift 6 strict + MainActor-default** — via decision (a); delete the 12 inline `SWIFT_VERSION = 5.0` overrides.
- **Dead-code sweep** — 13 dead `Views/Components/*.swift` files + `LanguagePickerView.swift` + `AudioRoutePickerWrapper.swift` (`AudioRoutePickerWrapper`/`Button`; **SAFE** — #104 — car-audio Media Mode uses the unrelated `AudioDevicePickerView`, Research verdict) + `MicButtonInspectorTests.swift` + `ProgressBarViewInspectorTests.swift`.

**Out:**
- `MCQOptionPicker.swift` — **LIVE, do NOT delete.** Sits in the same `Views/Components/` folder as the dead set; called out explicitly as a non-target to prevent an over-eager sweep.
- **Theme unification** — two parallel color enums (`Theme.Colors` / `Theme.Hangs.Colors`) confirmed but **note-only**; separate future issue (review kept it out of Top 10).
- **Any behavior change** — target / config / hygiene only; no product logic, UI, or API touched.

## Resolved design decisions

- **(a) Test config mechanism** — introduce test-target xcconfigs that `#include "Shared.xcconfig"`, paired with the existing `Debug.xcconfig` / `Release.xcconfig` build-mode files so tests keep `ENABLE_TESTABILITY` + `-Onone`; re-point the two test targets' base configs to them and delete the 12 inline overrides. Chosen over *"copy Shared's 3 settings into Debug/Release"* (those files are in the app's include chain too → the values would drift from Shared) and *"edit the 12 inline entries in place"* (leaves 12 drift sites). Result: `Shared.xcconfig` stays the **single source of truth** for Swift-6 + deployment target; Debug/Release stay the single source for build-mode settings.
- **(b) Both mock-injection paths preserved (behavior), retyped for de-opt** — the DEBUG `--ui-test-voice-ready` injector (`AppState.swift:77-79`) still injects a `MockSilenceDetectionService()`, and the UI-test `makeMockServices()` graph still supplies a mock silence service; only their **types** change (optional → non-optional) so T4's de-opt and this decision both execute literally. Exact restructure in T4. The `:81` real-injector `#available` guard is removed.
- **(c) Swift-6 compile fixes are in-scope but bounded; ONE STOP metric = distinct compile-error sites** — fix only real compile errors; leave the ~60 now-redundant manual `@MainActor` annotations in place (harmless). Two STOP gates share this single metric: **T3** (concurrency spike, before de-opt) stops at **> ~30 distinct compile-error sites**; **T4** (de-opt) stops at **> ~40** (see T4). Report the count and scope back rather than grinding — fail loud, no silent expansion into a test rewrite.
- **(c-STOP) Git disposition if either gate fires (fail-loud)** — commit 1 (T1 sweep) is independent and already landed. Commit 2 (T2+T3+T4) is one logical change that is only green at its end, so **do not commit any partial commit-2 state**: `git restore` `project.pbxproj`, delete the new `Tests-Debug/Tests-Release.xcconfig`, revert any T4 edits → HEAD returns to commit 1 (last green boundary); report the recorded distinct-compile-error-site count. Committing **T2 alone is explicitly rejected** — T2's whole effect is "tests now compile Swift 6", so with the spike red the branch would carry red tests, violating fail-loud.
- **(d) Sweep = one commit, deletions only** — git history is the safety net (repo convention); no move-to-archive for code.
- **(e) CI Xcode gate** — before the target raise merges, confirm the GH runner image actually resolves **Xcode 26.x with the iOS 26 SDK** (a `xcodebuild -version` + `-showsdks` check inside the ios-ci run, per Research CI verdict); the workflow's own comment warns the `Xcode_26.3` selector may lag the runner image and silently fall back.
- **(f) Commit order inside the issue** — **(1) dead-code sweep first** (pure deletions; shrinks the Swift-6 surface that step 2 must compile), then **(2) target raise + test unification** as one logical change. One logical change per commit, per the review recommendation. Run the (c) spike compile at the head of step 2, before touching the ~14 nil-branch sites, so scope is known before edits begin.

**Founder decision (defaulted, not blocking):** raising min iOS to 26.0 drops pre-iPhone-11 hardware. Default = **proceed** per the review's explicit recommendation — zero real users, founder device runs iOS 26+ (memory `user_device_ios26`). No founder action required unless they object.

**Sequencing (second-order):** run this issue **before** #113 — Decompose the QuizViewModel god object (deleting the ~14 `SilenceDetectionServiceProtocol?` nil-branches shrinks QuizViewModel ahead of its split) and ideally **before** #116 — Split AudioService into focused audio units (fewer optional audio paths to carve up). iOS-26-only also simplifies #97 — CarPlay support (drops sub-26 availability branching from its assumptions). This is the cheap hygiene pass that de-risks all three.

## Tasks (atomic)

> Ordered per decision (f): sweep first (commit 1), then target-raise + test-unification as **one logical change** (commit 2). Tasks are atomic units; commit grouping noted per task. Within commit 2 run the (c) spike (T3) **before** any app-code edit (T4). Paths below use `IOS=apps/ios-app/Hangs`.

### T1 — Dead-code sweep (→ commit 1: deletions only, decision d)
Delete 15 source files + 2 test files (Phase 1 grepped each to **zero** app-target call sites):
- **13 Components** (`$IOS/Hangs/Views/Components/*.swift`): `ScoreCard`, `StatsCard`, `SettingRow`, `AppLogo`, `CategoryBadge`, `LevelBadge`, `MicButton`, `ProgressBadge`, `ProgressBarView`, `ResultBadge`, `TrophyIcon`, `PrimaryButton`, `SecondaryButton`.
- **2 dead Views** (`$IOS/Hangs/Views/`): `LanguagePickerView.swift`; `AudioRoutePickerWrapper.swift` (defines `AudioRoutePickerWrapper` + `AudioRoutePickerButton`).
- **2 dead tests** (`$IOS/HangsTests/`): `MicButtonInspectorTests.swift`, `ProgressBarViewInspectorTests.swift`.
- Also delete **all 4** comment-only `PrimaryButton` references (lines 12/15/20/96) in `$IOS/HangsTests/Snapshots/PaywallViewSnapshotTests.swift` (the review's edit-trap; required for acceptance #2 grep-zero). Note the bare word `PrimaryButton` only — `HangsPrimaryButton` (HangsButtonInspectorTests / HomeViewSnapshotTests) is a different **live** symbol and is not matched by the `-w PrimaryButton` grep, so leave it.
- Remove all 17 file refs from `project.pbxproj` (PBXBuildFile + PBXFileReference + Sources build phase entries).
- **DO NOT DELETE — LIVE, same folders:** `$IOS/Hangs/Views/Components/MCQOptionPicker.swift`; `$IOS/Hangs/Views/AudioDevicePickerView.swift` (#104 Media-Mode mic picker); the whole `$IOS/Hangs/Views/Components/Hangs/` design-system set.
- Verify: the `Hangs-Local` scheme still builds after the deletions.

### T2 — Test-target xcconfigs + re-point + strip inline overrides (→ commit 2, step A)
- Create `$IOS/Configuration/Tests-Debug.xcconfig` = `#include "Shared.xcconfig"` + `#include "Debug.xcconfig"`; `Tests-Release.xcconfig` = `#include "Shared.xcconfig"` + `#include "Release.xcconfig"` — mirrors the app's `Debug-Local` composition (build-type + base). Shared carries Swift-6 + deployment target; Debug/Release carry `ENABLE_TESTABILITY`/`-Onone` (Debug) and `-O` (Release).
- Re-point 12 `baseConfigurationReference` (HangsTests + HangsUITests, 6 configs each): the 6 `Debug-*` configs → `Tests-Debug.xcconfig`, the 6 `Release-*` configs → `Tests-Release.xcconfig` (currently → bare `Debug.xcconfig` `F6DEB984…` / `Release.xcconfig` `D7DFEF43…`).
- Delete the **24 inline entries** in those 12 blocks: `SWIFT_VERSION = 5.0` (×12) + `IPHONEOS_DEPLOYMENT_TARGET = 18.0` (×12). **Leave** the inline `SWIFT_EMIT_LOC_STRINGS = NO` + `STRING_CATALOG_GENERATE_SYMBOLS = NO` — they must survive as test-only overrides of Shared's `YES`.
- **Verify (gate note 1 — NO overrides survive the base re-point):** `cd $IOS && xcodebuild -showBuildSettings -target HangsTests -configuration Debug-Local` resolves `SWIFT_EMIT_LOC_STRINGS = NO` **and** `STRING_CATALOG_GENERATE_SYMBOLS = NO` (inline still wins) **and** `SWIFT_VERSION = 6.0` (Shared now wins).
- **Verify (gate note 3 — env-drop loses nothing):** the 12 test config blocks reference no env-only setting — grep them for `API_BASE_URL|SENTRY_DSN|ENVIRONMENT_NAME|BUNDLE_DISPLAY_NAME` → 0. The new chain (Shared + Debug/Release, no `Local/Prod/Staging`) is equivalent-plus-Shared to the old (base = bare Debug/Release; env never entered the test chain), so nothing env-specific is lost.

### T3 — Swift-6 test spike compile + bounded fixes (→ commit 2, step B; before any app-code edit)
- With T2 in place the test targets now compile Swift-6 strict + MainActor-default. Run the spike once and count **distinct compile-error sites**: `cd $IOS && xcodebuild build-for-testing -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'`.
- Fix only real compile errors — expect them in async/actor-hop suites + non-Sendable mocks crossing isolation (`CommandListenerTests`, `QuizViewModelStreamingTests`, `AudioServiceTests`, `EarconTests`). The ~60 now-redundant manual `@MainActor` annotations stay in place (harmless; MainActor-default may surface Sendable-check interactions in those async suites — the spike is the instrument that measures it).
- **STOP threshold (decision c):** if the spike surfaces **> ~30 distinct compile-error sites**, stop — do not grind into a test rewrite. Report the count to the coordinator, apply the STOP git disposition (decision c-STOP), and scope back. Fail loud. This gate runs **before** T4's de-opt breakages exist, so it bounds only the Swift-6/concurrency fallout on the existing test corpus.

### T4 — Raise deployment target 18.0 → 26.0 + de-optionalize (→ commit 2, step C)
- **Target:** `$IOS/Configuration/Shared.xcconfig:42` `IPHONEOS_DEPLOYMENT_TARGET = 18.0` → `26.0` (single source of truth; app + all 6 app configs inherit; test targets inherit via T2).
- **Guards (the 2 real hits):** delete the `@available(iOS 26, *)` class attribute at `SilenceDetectionService.swift:89`; delete the real-injector `if silence == nil, #available(iOS 26, *)` at `AppState.swift:81`. Also update the stale `@available(iOS 26,*)` **doc-comment** at `VADTuning.swift:83` so acceptance #6 grep-zero holds (comment, not a guard).
- **De-opt mechanism (chosen — keeps the ~50 arg-omitting call sites compiling):** property becomes **non-optional**; the init param keeps a **default, but the default is the real service** — `silenceDetectionService: SilenceDetectionServiceProtocol = SilenceDetectionService()`. Verified safe: `SilenceDetectionService.init` (`:139`) only sets stored properties — no `AVAudioEngine`/`SpeechAnalyzer`/auth until `start`/`requestAuthorizationAndPrepareAssets`, so constructing it as a test default is inert and on the Simulator resolves `.unavailable` exactly as the old `nil` did. Production never reaches the default (`AppState.makeQuizViewModel` `:183` + the AppState main init pass explicitly). **Not** `MockSilenceDetectionService()` as the default — that mock is DEBUG-only app code, wrong in a production signature.
- **The 6 `SilenceDetectionServiceProtocol?` decls → non-optional** (drives acceptance #6 to 0): properties `QuizViewModel.swift:426` + `AppState.swift:18`; init-param defaults `QuizViewModel.swift:484` + `AppState.swift:157` (`= nil` → `= SilenceDetectionService()`); AppState main-init local `:71`; UITestSupport tuple member `:37`. (Init-body assignments `QuizViewModel.swift:491`, `AppState.swift:166`, and the `:183` pass compile unchanged once the types are non-optional.)
- **AppState main init `:71–92` (reconciles decision b):** `var overrideSilence: SilenceDetectionServiceProtocol? = nil`; keep the DEBUG `--ui-test-voice-ready` branch assigning `MockSilenceDetectionService()` into it (behavior preserved); then `silenceDetectionService = overrideSilence ?? SilenceDetectionService()`. Fix the `:146` availability log (source no longer optional).
- **UITestSupport mock path (reconciles decision b):** `makeMockServices()` tuple member `:37` → non-optional; its return at `:88` `nil` → `MockSilenceDetectionService()`; `AppState.swift:38` `silenceDetectionService = mocks.silence` then type-checks. Mechanical type change, not a behavior change (UI-test graph carries an inert mock, not nil).
- **Test construction sites that BREAK (the honest de-opt surface; everything else omits the arg and rides the real default):** (i) 3 explicit literal-`nil` passes → `MockSilenceDetectionService()`: `AudioServiceTests.swift:475`, `QuizViewModelSubmissionRaceTests.swift:37`, `QuizViewModelStreamingTests.swift:34`. (ii) 3 helper factories typing `silence: MockSilenceDetectionService?` and passing it optionally → de-optionalize the helper param (default `= MockSilenceDetectionService()`) and drop the downstream `#require(silence)`: `CommandListenerTests.swift:28/36`, `VoiceCommandObservabilityTests.swift:22/29`, `ScenePhaseTeardownTests.swift:27/34`. Sites passing a concrete `MockSilenceDetectionService` inline or via a `let` (`EarconTests`, `StartCommandTests`, `SkipCancelWordTests`, `SharedEngineTests`, `ConfirmResultCommandTests`, `QuizViewModelTimerTests`) already conform — **untouched**.
- **~14 consumer nil-branches** (unchanged from Phase 1) — drop the `?? .unknown` / optional-chains: `QuizViewModel+CommandListener.swift:80,102` · `+Audio.swift:31,60,74,98,128` · `QuizViewModel.swift:500,501,1206,1482` · `+Recording.swift:62` · `SettingsView.swift:657`. Guarantees SpeechAnalyzer/VAD present on every install.
- **5 snapshot `.txt` re-records (non-gating):** `HomeViewSnapshotTests`, `QuestionViewSnapshotTests` (asking/recording), `ResultViewSnapshotTests` (correct/incorrect) currently dump `- silenceDetectionService: nil`; with the real default they dump a non-nil service → **re-record signal** per the iOS-rules policy (surface for sign-off, not a hard fail).
- **T4 STOP gate (decision c, same single metric as T3):** after applying the de-opt, `cd $IOS && xcodebuild build-for-testing -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest'` and count **distinct compile-error sites**. Expected honest surface ≈ 25 (the ~14 consumer branches + ~11 plumbing/injection/test sites above). If it exceeds **> ~40 distinct compile-error sites**, the default-value mechanism failed to shield the ~50 arg-omitting call sites — **STOP, apply the STOP git disposition (decision c-STOP), and report the count**; do not hand-edit 50 sites. Fail loud.

### T5 — Verification tail (→ folds into commit 2; CI-workflow edit may be its own small commit)
- **Full suite green:** `cd $IOS && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` — HangsTests + HangsUITests all pass. Re-run the 3 known flaky async voice tests once before declaring red (memory `project_ios_ci_snapshot_and_flaky_async`).
- **CI Xcode gate (decision e):** add an iOS-26-SDK assertion to `.github/workflows/ios-ci.yml` → job `build-and-test` → step "Show build environment": `xcodebuild -showsdks | grep -q iphoneos26 || exit 1`, so the run fails loud if the `Xcode_26.3` selector falls back to an older default Xcode lacking the 26 SDK.
- **Founder decision (defaulted, non-blocking):** raising min iOS to 26.0 drops pre-iPhone-11 hardware → **proceed** (zero real users, founder device runs iOS 26+). No founder action required unless they object.

## Acceptance (machine-evaluable)

Run from repo root unless noted; `IOS=apps/ios-app/Hangs`. Each check is falsifiable.

1. **Dead files gone** — every one of the 17 paths is absent (`ls` errors), incl. `$IOS/HangsTests/MicButtonInspectorTests.swift` and `$IOS/HangsTests/ProgressBarViewInspectorTests.swift`.
2. **Dead symbols zero** — `grep -rn -w -e ScoreCard -e StatsCard -e SettingRow -e AppLogo -e CategoryBadge -e LevelBadge -e MicButton -e ProgressBadge -e ProgressBarView -e ResultBadge -e TrophyIcon -e PrimaryButton -e SecondaryButton -e LanguagePickerView -e AudioRoutePickerWrapper -e AudioRoutePickerButton $IOS/Hangs $IOS/HangsTests $IOS/HangsUITests` → 0 hits.
3. **Live files present** — `$IOS/Hangs/Views/Components/MCQOptionPicker.swift` and `$IOS/Hangs/Views/AudioDevicePickerView.swift` both still exist.
4. **No Swift-5 test override** — `grep -c "SWIFT_VERSION = 5.0" $IOS/Hangs.xcodeproj/project.pbxproj` → 0.
5. **Target raised** — `grep -rn "IPHONEOS_DEPLOYMENT_TARGET = 18.0" $IOS/Configuration $IOS/Hangs.xcodeproj/project.pbxproj` → 0; `grep -c "IPHONEOS_DEPLOYMENT_TARGET = 26.0" $IOS/Configuration/Shared.xcconfig` → 1.
6. **Guards gone / de-optionalized** — path is `$IOS/Hangs` (the Swift source root; `$IOS/Hangs/Hangs` does **not** exist — that was a vacuous check). `grep -rn "@available(iOS 26" $IOS/Hangs` → 0 (**baseline today: 2** — `SilenceDetectionService.swift:89` class attr + `VADTuning.swift:83` doc-comment). `grep -rn "SilenceDetectionServiceProtocol?" $IOS/Hangs` → 0 (**baseline today: 6** — `QuizViewModel.swift:426,484` · `AppState.swift:18,71,157` · `UITestSupport.swift:37`). Both must fall from their baseline to 0 — this is the sole machine-check for T4's two core deliverables.
7. **NO overrides survived (gate 1)** — `cd $IOS && xcodebuild -showBuildSettings -target HangsTests -configuration Debug-Local` shows `SWIFT_EMIT_LOC_STRINGS = NO`, `STRING_CATALOG_GENERATE_SYMBOLS = NO`, and `SWIFT_VERSION = 6.0`.
8. **Env-drop clean (gate 3)** — the 12 test config blocks in `project.pbxproj` contain no `API_BASE_URL` / `SENTRY_DSN` / `ENVIRONMENT_NAME` / `BUNDLE_DISPLAY_NAME` (grep → 0).
9. **Spike bounded (decision c)** — recorded T3 distinct-compile-error-site count ≤ ~30 **and** T4 de-opt distinct-compile-error-site count ≤ ~40 (otherwise the matching STOP was correctly triggered, the STOP git disposition (decision c-STOP) applied, and this issue pauses).
10. **Suite green** — the T5 `xcodebuild test` command exits 0 with 0 failing tests (flaky-async single re-run allowed).
11. **CI 26-SDK gate** — `.github/workflows/ios-ci.yml` "Show build environment" step contains the `xcodebuild -showsdks | grep -q iphoneos26` assertion, and a `build-and-test` run is green on the 26.0 target.

## Research (Phase 1, 2026-07-20)

Anchors only; see [source review](../research/ios-architecture-review-2026-07-18.md) items 5, 6.

### Target raise — config topology
- **Deployment-target sites (13):** `Shared.xcconfig:42` (18.0; covers the app target + all 6 app configs — verified 0 inline `IPHONEOS`/`SWIFT_VERSION` overrides on app configs `5090EC5D/5E/5F/60,077E4E24,1251B65F`) **+ 12 inline test-target entries** in `project.pbxproj` (HangsTests 419/441/463/485/507/529, HangsUITests 550/571/592/613/634/655).
- **Swift-version sites:** app = `Shared.xcconfig:32` (6.0) + `:33` strict-complete + `:35` MainActor-default. Tests pin `SWIFT_VERSION = 5.0` inline ×12 (`project.pbxproj` 427/449/471/493/515/537/558/579/600/621/642/663).
- **No test-specific xcconfig exists.** Test targets' base config = `Debug.xcconfig`/`Release.xcconfig`, which do **not** `#include Shared.xcconfig` — Shared enters only via the env layer (`Local/Prod/Staging.xcconfig`, which tests don't reference). Fix options (Phase 2): add Shared's 3 settings to Debug/Release, or re-point test base config, or edit the 12 inline entries. Note Debug/Release are also in the app's include chain.
- **Two availability guards:** `SilenceDetectionService.swift:89` (`@available(iOS 26,*)` on the class) · `AppState.swift:81` (`if silence == nil, #available(iOS 26,*)` — the sole real injector; `:77-79` mock path stays for UI tests).
- **~14 optional nil-branch sites** on `SilenceDetectionServiceProtocol?`: `QuizViewModel+CommandListener.swift:80,102` · `+Audio.swift:31,60,74,98,128` · `QuizViewModel.swift:500,501,1206,1482` · `+Recording.swift:62` · `AppState.swift:146` (log) · `SettingsView.swift:657`. De-optionalize the property/init plumbing too: `QuizViewModel.swift:426,484,491`, `AppState.swift:18,157,166,183` (+ drop `?? .unknown` / optional-chains).

### Swift-6 test blast radius — MODERATE, bounded
74 test files; **60 already carry manual `@MainActor`** (authors compensated for the Swift-5 no-default-isolation). Under Swift 6 + MainActor-default those become largely redundant (optional cleanup), so compile risk concentrates in async/actor-hop suites (`CommandListenerTests`, `QuizViewModelStreamingTests`, `AudioServiceTests`, `EarconTests`) + any non-Sendable mock crossing isolation. **Not a rewrite.** The 3 known flaky async voice tests (memory `project_ios_ci_snapshot_and_flaky_async`) are a runtime re-run concern, not a compile blocker. A definitive error count needs a spike compile — recommend Phase 2/4 flip one test config + `xcodebuild test` once.

### Dead-code sweep — all zero app-target call sites (grepped each symbol)
- **13 Components** (`Views/Components/*.swift`): ScoreCard, StatsCard, SettingRow, AppLogo, CategoryBadge, LevelBadge, MicButton, ProgressBadge, ProgressBarView, ResultBadge, TrophyIcon, PrimaryButton, SecondaryButton. ⚠ `MCQOptionPicker.swift` in the same folder is **LIVE** — do not delete. Live design system = `Views/Components/Hangs/`.
- **Dead Views:** `LanguagePickerView.swift`; `AudioRoutePickerWrapper.swift` (defines `AudioRoutePickerWrapper` + `AudioRoutePickerButton`).
- **Dead tests:** `MicButtonInspectorTests.swift` (instantiates `MicButton`), `ProgressBarViewInspectorTests.swift` (instantiates `ProgressBarView`) — exercise only dead code → delete. `PaywallViewSnapshotTests.swift` names "PrimaryButton" in **comments only** (the review's edit-trap) — not a live dep; optional comment cleanup.
- **#104 × AudioRoutePicker VERDICT — SAFE TO DELETE.** #104's Settings mic picker uses `AudioDevicePickerView` (live in `SettingsView.swift` + `HomeView.swift`) + `setPreferredInput` (#104 Acceptance :54). `AudioRoutePickerWrapper` wraps `AVRoutePickerView` (system AirPlay output route) — a different concern, zero call sites.
- **Theme (OUT OF SCOPE — note only):** two parallel color enums confirmed — `Theme.Colors` (`Theme.swift:15`) + `Theme.Hangs.Colors` (`Theme+Hangs.swift:12-13`). Review kept theme unification out of Top 10; leave for a separate issue.

### CI verdict — OK
`.github/workflows/ios-ci.yml` selects `Xcode_26.3` (fallback `/Applications/Xcode.app`), `runs-on: macos-latest`, destination iPhone 17 Pro `OS=latest`. Xcode 26.3 ships the iOS 26 SDK → a 26.0 target compiles/tests on CI. Minor risk: the file's own comment warns Xcode 26.3 "may take time to land on GH runners" — if the runner falls back to an older default Xcode lacking the 26 SDK, the build breaks; Phase 2 should confirm the runner image has 26.x (mba builds on Xcode 26.5/26.6 per memory).

**Prior art:** n/a (config/hygiene). **Web pass:** skipped — config/hygiene only; iOS 26 SDK availability verified locally (ios-ci Xcode 26.3 + repo memory), no external unknowns.

**No new product question** — the only decision (drop pre-iPhone-11 hardware) is already surfaced in "Why" and defaulted to proceed.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ✅ done | ready-check READY · design-soundness SOUND 0.88 |
| 4 · Impl-plan         | ✅ done | — |
| 5 · Impl-plan review  | 🔄 re-gate | cycle 1: ready-check NOT-READY (1) · design-soundness UNSOUND 0.63 (2) — fixed, re-gate |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 (Phase 5 cycle 1 re-plan — fixed acceptance #6 path + baselines, honest T4 de-opt surface + mechanism, decision-b reconcile, dual STOP gates on one metric + git disposition, "all 4" PrimaryButton lines) · **Next:** Phase 5 re-gate · **Gate attempts:** P3 1/3 (PASS) · P5 1/3
