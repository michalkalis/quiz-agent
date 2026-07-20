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
- **(b) Mock injection path stays** — `AppState.swift:77-79` (the UI-test mock injector for `SilenceDetectionService`) is untouched; only the `:81` real-injector `#available` guard is removed.
- **(c) Swift-6 compile fixes are in-scope but bounded** — fix only real compile errors; leave the ~60 now-redundant manual `@MainActor` annotations in place (harmless). If the spike compile surfaces a large error count (> ~30 sites), **STOP and report back** rather than grinding — fail loud, don't silently expand scope into a test rewrite.
- **(d) Sweep = one commit, deletions only** — git history is the safety net (repo convention); no move-to-archive for code.
- **(e) CI Xcode gate** — before the target raise merges, confirm the GH runner image actually resolves **Xcode 26.x with the iOS 26 SDK** (a `xcodebuild -version` + `-showsdks` check inside the ios-ci run, per Research CI verdict); the workflow's own comment warns the `Xcode_26.3` selector may lag the runner image and silently fall back.
- **(f) Commit order inside the issue** — **(1) dead-code sweep first** (pure deletions; shrinks the Swift-6 surface that step 2 must compile), then **(2) target raise + test unification** as one logical change. One logical change per commit, per the review recommendation. Run the (c) spike compile at the head of step 2, before touching the ~14 nil-branch sites, so scope is known before edits begin.

**Founder decision (defaulted, not blocking):** raising min iOS to 26.0 drops pre-iPhone-11 hardware. Default = **proceed** per the review's explicit recommendation — zero real users, founder device runs iOS 26+ (memory `user_device_ios26`). No founder action required unless they object.

**Sequencing (second-order):** run this issue **before** #113 — Decompose the QuizViewModel god object (deleting the ~14 `SilenceDetectionServiceProtocol?` nil-branches shrinks QuizViewModel ahead of its split) and ideally **before** #116 — Split AudioService into focused audio units (fewer optional audio paths to carve up). iOS-26-only also simplifies #97 — CarPlay support (drops sub-26 availability branching from its assumptions). This is the cheap hygiene pass that de-risks all three.

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
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 (Phase 2 plan complete) · **Next:** Phase 3 (dual gate) · **Gate attempts:** P3 0/3 · P5 0/3
