# Issue #56 — iOS text localization (String Catalog)

**Triage:** refactor · in progress
**Status:** Plan written 2026-06-12; atomized into 9 Ralph `- [ ]` tasks + 1 `- [HUMAN]` 2026-06-13. **Reviewed + fact-corrected 2026-06-15** against the live codebase (see "Review corrections" below); phase 1 (56.1a/56.1b) started on the local machine. English is the source language; Slovak and other languages come later as pure translation work in the catalog.

### Review corrections (2026-06-15) — plan vs. verified codebase state

The strategy (String Catalog, English-as-key, compiler extraction for views + `String(localized:)` for non-view code) is sound and matches Apple best practice. These factual fixes were applied after first-hand verification:

1. **Compiler extraction is ALREADY ON.** `SWIFT_EMIT_LOC_STRINGS = YES`, `STRING_CATALOG_GENERATE_SYMBOLS = YES`, and `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` are all already set in `Configuration/Shared.xcconfig` (test targets override `SWIFT_EMIT_LOC_STRINGS = NO`, which is exactly what 56.2 wanted). → **56.2's flag-flip is already done**; the remaining 56.2 work is just adding the `Localizable.xcstrings` file + the pilot gate.
2. **Test count is ~395, not 363** (suite uses Swift Testing `@Test`, not XCTest `func test`). `find(text:)` call sites are **64, not 56**, across 13 test files. `NetworkError` has **6 cases, not 5**.
3. **AppErrorModel has 14 pairs — the appendix was missing one** ("História otázok je plná" / history-at-capacity). Now preserved in full below.
4. **`AppErrorModelTests` is NOT purely non-emptiness** — two tests (`cancellationError`, `urlErrorCancelled`) assert `!title.lowercased().contains("cancelled")`, a Slovak-era guard against leaking raw English error text. The accurate English title "Action cancelled" trips it. 56.1a drops that now-obsolete substring guard (the meaningful `retryAction == .dismiss` assertion stays).
5. **56.1b scope refined:** only **category** display names are truly duplicated (`Config.categoryOptions` ↔ `QuizSettings.categoryDisplayName()`). **Difficulty is NOT duplicated** (`difficultyDisplayName()` is dynamic capitalization). **Age-appropriate IS** duplicated but `ageAppropriateDisplayName()` has zero callers → deferred to the 56.4 sweep (delete or single-source then). The code comments already make **`Config` the source of truth** ("mirrors Config… keep in sync"), so Config is the owner, not the model as the plan guessed.
6. **"3 known pre-existing snapshot fails from #54" is unverified** — no skip/xfail markers found in the test code. Confirm the actual baseline at 56.5 rather than assuming 3 fails.

## Goal

Every user-facing string in the iOS app lives in a single **String Catalog** (`Localizable.xcstrings`) so adding a new language later is a translation task, not a code change. Source language: **English**. No new languages shipped in this issue — the deliverable is full extraction + infrastructure.

Verifiable success criteria:
1. Building the app populates `Localizable.xcstrings` with all view strings (compiler extraction on).
2. Zero user-facing string literals remain outside the catalog (manual sweep checklist below, file by file).
3. All 363 unit tests pass (ViewInspector + snapshot).
4. App runs identically in English — no visible copy change except the AppErrorModel fix (see 56.1).

## Chosen approach: String Catalog (`.xcstrings`)

The modern Apple-standard mechanism (Xcode 15+, fully supported on our iOS 18.0 target):

- One `Localizable.xcstrings` file replaces legacy `Localizable.strings` + `.stringsdict`. Handles plurals and device variants natively; Xcode shows per-language translation progress and marks stale entries.
- **Compiler extraction**: with `SWIFT_EMIT_LOC_STRINGS = YES` (**already set** in `Shared.xcconfig` as of review 2026-06-15), Xcode auto-populates the catalog from SwiftUI `Text("…")`, `Button("…")`, `Label`, `navigationTitle`, etc. — these literals are already `LocalizedStringKey`, so most view code needs **no rewrite**, just a build.
- Non-view code (ViewModels, Services, error enums, model display names) uses `String(localized:comment:)` explicitly.
- **Key strategy: English source text as the key** (Apple default). This keeps view code readable, lets compiler extraction work, and — critically — keeps ViewInspector `find(text:)` assertions passing, because the resolved English value equals the literal. Semantic keys (`"question.skip.button"`) were considered and rejected: they'd force rewriting all 56 `find(text:)` assertions and every `Text()` call for no benefit at our scale (~130–150 strings).

Rejected alternatives: legacy `.strings`/`.stringsdict` (superseded, no plural editor, no staleness tracking); third-party SwiftGen/L10n enums (extra build tooling, fights compiler extraction, overkill for a solo project).

## Current state (analysis 2026-06-12)

- **No catalog file yet, but the build settings are primed**: no `Localizable.xcstrings`, no `.lproj`, no `NSLocalizedString`/`String(localized:)` anywhere. `knownRegions = (en, Base)`. **`SWIFT_EMIT_LOC_STRINGS = YES` is already set** (corrected 2026-06-15) along with `STRING_CATALOG_GENERATE_SYMBOLS`/`LOCALIZATION_PREFERS_STRING_CATALOGS` — only the catalog file is missing.
- **~130–150 distinct client-side strings** across ~25 files. Top offenders: `AppErrorModel.swift` (14 title+description pairs), `OnboardingView` (~18), `QuestionView` (~14), `ResultView` (~12), `SettingsView` (~12), `AnswerConfirmationView` (~10), `CompletionView`, `PaywallView`, `MinimizedQuizView`, `AudioDevicePickerView`.
- **`AppErrorModel.swift` is entirely in Slovak** — the only non-English copy in the app. Error screens show Slovak regardless of language. Must become English source text first.
- **Display-name duplication**: category/difficulty display names exist in both `Utilities/Config.swift` and `Models/QuizSettings.swift` — single-source before extraction so each string is in the catalog once.
- **Tests**: snapshot tests use `.stableDump` (view-model state, not rendered text) → safe (one exception: `PaywallViewSnapshotTests` uses raw `.dump`, still state not pixels). 64 ViewInspector `find(text:)` assertions (across 13 files) match English literals → safe **only** with the English-as-key strategy (verify in 56.2 pilot).
- **Backend content is out of scope client-side**: question text, answers, feedback, evaluation come from the API already localized via `session.language`. Category display names shown in UI are client-side and ARE in scope.
- **Intentionally locale-fixed code — do not touch**: `MCQTranscriptMatcher` and `LogEntry` use `en_US_POSIX` on purpose (ASCII matching, log timestamps).

## Tasks

### Ralph atomic task list (run in order; full detail in §56.x below)

All source paths below are under `apps/ios-app/Hangs/` (e.g. `apps/ios-app/Hangs/Hangs/Models/AppErrorModel.swift`).
Build + test from `apps/ios-app/Hangs` (scheme `Hangs-Local`); the XcodeBuildMCP server is attached for `build_sim`/`xcodebuild`.

Pick the **first unchecked `- [ ]`** each iteration. **Hard gate at 56.2** — if the
pilot test fails, append a `## BLOCKER` note and stop; do NOT proceed to mass extraction.
Each task must end with a green build + its named tests before being checked off.

- [x] **56.1a** — Rewrite `AppErrorModel.swift` copy Slovak→English (14 title+description pairs); Slovak preserved in appendix below. Updated 2 obsolete `contains("cancelled")` test guards → assert intentional copy. **Done 2026-06-15: 19/19 `AppErrorModelTests` pass, module builds.** (§56.1)
- [x] **56.1b** — Single-source the duplicated **category** display names: `QuizSettings.categoryDisplayName()` now derives from `Config.categoryOptions` (**Config is the owner** per existing "mirrors Config" comments). Difficulty non-duplicated (dynamic) — no-op. Age-appropriate dup deferred to 56.4 (its method is unused). **Done 2026-06-15: module builds, no tests assert category labels.** (§56.1)
- [x] **56.2** — Added empty `Localizable.xcstrings` at `Hangs/Hangs/Localizable.xcstrings`. Project uses **synchronized file groups** (objectVersion 77) → file auto-joins the Hangs target, no pbxproj edit. Build flags already in place. **PILOT GATE PASSED 2026-06-15:** `OnboardingViewStructureTests` (11 `find(text:)`) + `OnboardingPageIndicatorColorTests` + `HomeViewSnapshotTests` all green with the catalog present → English-as-key holds. Build SUCCEEDED. (§56.2)
- [ ] **56.3a** — Convert `QuizViewModel` (+`+Recording`/`+Audio`) user-facing strings + `NetworkService.NetworkError.errorDescription` to `String(localized:comment:)`. Build + targeted tests green. (§56.3)
- [ ] **56.3b** — Convert display-name computed properties to `String(localized:)`: categories/difficulties (post-56.1b), `AudioMode`, `Language`, `ListeningPill.Mode.copy`, `HangsResultKind.label`, plus `AppErrorModel` (post-56.1a English copy). Build + tests green. (§56.3)
- [ ] **56.3c** — Convert accessibility labels/hints + interpolated/plural strings to `String(localized:)` with `comment:`; keep interpolation inside the string; add plural variants in the catalog editor; exclude debug-only UI via `Text(verbatim:)`. Build + tests green. (§56.3)
- [ ] **56.4** — File-by-file sweep of `Views/**` + `Models|Services|ViewModels|Utilities` against the inventory; `Text(verbatim:)` for brand/raw/non-localizable; catalog hygiene (mark "Don't translate", add ambiguous-key comments); add the `String(localized:)` guardrail one-liner to `.claude/rules/ios.md`. (§56.4)
- [ ] **56.5** — Full unit suite (≈395 tests). Establish the actual pre-existing-fail baseline first (the "3 from #54" figure is unverified — no skip markers found). Confirm the app still builds + runs in English. (§56.5)
- [HUMAN] **56.6** — Pseudo-localization visual smoke (Xcode "Double-Length Pseudolanguage") across every screen; eyeball for missed literals. Visual — human-only.

### 56.1 Pre-work (no localization yet)
- Rewrite `AppErrorModel.swift` copy Slovak → English (14 title+description pairs). Plain English literals only — `String(localized:)` wrapping happens later in 56.3b. The Slovak text becomes the first `sk` translation when that language lands — preserved in full in the appendix below.
- Single-source the duplicated **category** display names: `QuizSettings.categoryDisplayName()` derives from `Config.categoryOptions` (Config owns it). Difficulty needs nothing. Age-appropriate deferred to 56.4.
- Verify: `AppErrorModelTests` still pass — note two tests guard `!title.contains("cancelled")` (Slovak-era leak guard); drop that obsolete substring assertion since "Action cancelled" is now the intentional English title. App builds.

### 56.2 Infrastructure + pilot — DONE 2026-06-15

- Added empty `Localizable.xcstrings` at `Hangs/Hangs/Localizable.xcstrings`. **No pbxproj edit needed** — the project uses Xcode 16 `PBXFileSystemSynchronizedRootGroup` (objectVersion 77), so any file dropped in `Hangs/` auto-joins the Hangs app target.
- Build flags confirmed already set (`SWIFT_EMIT_LOC_STRINGS = YES` app / `NO` tests).
- **Extraction caveat (important for 56.3+):** `xcodebuild` CLI does **not** write extracted strings back into the *source* `.xcstrings` (it stayed `strings: {}` after a clean build), even though the compiler emitted 307 `.stringsdata` files. The source-catalog write-back is an **Xcode IDE background task** — open the project in Xcode (or build there) to populate the visible catalog. The empty catalog is harmless: missing keys fall back to the literal, which is exactly the English-as-key behaviour. So adding plural/translation entries (56.3c) will need the catalog populated in the IDE first, or hand-authored `.xcstrings` entries.
- **Pilot gate PASSED:** `OnboardingViewStructureTests` (5 tests, 11 `find(text:)`) + `OnboardingPageIndicatorColorTests` (2 tests) + `HomeViewSnapshotTests` (1) — all green with the catalog present. English-as-key assumption holds; safe to proceed to mass extraction. (Note: filename `OnboardingViewInspectorTests.swift` ≠ type names — the suites are `OnboardingViewStructureTests` / `OnboardingPageIndicatorColorTests`; use those in `-only-testing`.)

### 56.3 Non-view strings → `String(localized:)`
Compiler extraction does not cover plain `String` contexts. Convert explicitly, with `comment:` for translator context:
- `QuizViewModel` + extensions (`+Recording`, `+Audio`): user-facing `errorMessage`/`setError` strings (~12).
- `NetworkService.NetworkError.errorDescription` (5).
- `AppErrorModel` (post-56.1 English copy).
- Display-name computed properties: categories/difficulties (post-56.1 single source), `AudioMode`, `Language` display names, `ListeningPill.Mode.copy`, `HangsResultKind.label`.
- Accessibility labels/hints built as plain strings (StatsCard, ScoreCard, CategoryBadge, AnswerOption, ProgressBadge, ProgressBarView, MinimizedQuizView, AnswerConfirmationView, ContentView/ErrorView, ImageQuestionView, PrimaryButton/HangsButton "Loading").
- Interpolated strings: keep interpolation inside the localized string (`"Next in \(n)s"` → one catalog entry with placeholder), never concatenate fragments. Plural-sensitive ones (`"\(n) points"`, `"out of \(n)"`) get plural variants in the catalog editor.
- Debug-only UI (`DebugErrorDetailsView`, `"View Logs"`, `"OSLogStore"`): **exclude** — wrap in verbatim `Text(verbatim:)` or leave as-is; developer strings don't get localized.

### 56.4 Sweep + guardrail
- File-by-file sweep of `Hangs/Views/**` and `Hangs/Models|Services|ViewModels|Utilities` against the inventory (analysis report) to catch stragglers; check `Text(verbatim:)` is used for non-localizable display (brand wordmark `"hangs."`, raw values, SF symbol names).
- Catalog hygiene pass in Xcode: mark brand/verbatim entries "Don't translate", add comments where the key alone is ambiguous (e.g. `"Skip"` button vs `"Skip"` onboarding).
- Guardrail against regressions: enable `SWIFT_EMIT_LOC_STRINGS` keeps new SwiftUI literals flowing into the catalog automatically; for non-view code add a one-line note to `.claude/rules/ios.md` ("user-facing strings → `String(localized:)`, never bare literals").

### 56.5 Verification
- Full test suite (~395 tests). Record the pre-existing-fail baseline before changes rather than assuming "3 from #54" (unverified).
- Run app in simulator with **pseudo-localization** (`-AppleLanguages` / Xcode scheme "Double-Length Pseudolanguage") → every screen shows doubled text ⇒ extraction is complete; any normal-length string = missed literal.
- Smoke-run key flows (onboarding, quiz, result, completion, settings, paywall, error screen) in English.

### Out of scope (future issues)
- Actual Slovak/Czech/German… translations — pure catalog work once this lands; Slovak source text preserved in appendix.
- Backend content localization (already handled via `session.language`).
- App Store metadata localization (belongs to #50 — App Store Connect listing).
- In-app UI-language override (UI follows device language; quiz-content language stays a separate, existing setting).

## Risks

| Risk | Mitigation |
|---|---|
| ViewInspector `find(text:)` breaks despite English-as-key | 56.2 pilot gate before mass extraction |
| Interpolated/plural strings extracted wrong | Hand-review catalog entries with placeholders; plural variants in editor |
| `"language"` setting confusion: quiz-content language ≠ UI language | Naming pass in SettingsView copy during 56.3 (e.g. "Quiz language") |
| Slovak error copy lost | Preserved in appendix below for the future `sk` translation |

## Appendix — current Slovak AppErrorModel copy (future `sk` translations)

Full preservation of all 14 title+description pairs from `Hangs/Models/AppErrorModel.swift` before 56.1a rewrites them to English. These become the `sk` catalog values once Slovak lands. (Verified complete 2026-06-15 — the earlier list was missing the history-at-capacity pair and all descriptions.)

| # | Case | Title (sk) | Description (sk) |
|---|------|-----------|------------------|
| 1 | `historyAtCapacity` | História otázok je plná | Vymaž históriu otázok v Nastaveniach (Reset question history) a začni novú hru. |
| 2 | cancellation | Akcia bola zrušená | Odoslanie sa prerušilo. Skús odpovedať znova. |
| 3 | no internet / connection lost | Nie je internetové pripojenie | Skontroluj Wi-Fi alebo mobilné dáta a skús to znova. |
| 4 | timed out | Čas vypršal | Server odpovedal príliš pomaly. Skús to znova. |
| 5 | dailyLimitReached | Denný limit dosiahnutý | Dnes si odpovedal na maximálny počet otázok. Vráť sa zajtra. |
| 6 | sessionNotFound | Relácia vypršala | Táto kvízová relácia už nie je aktívna. Začni novú hru. |
| 7 | serverError ≥500 | Chyba servera | Niečo sa pokazilo na našej strane. Skús to znova. |
| 8 | serverError 429 | Príliš veľa požiadaviek | Spomaľ trochu a skús to znova za chvíľu. |
| 9 | decodingError / invalidResponse | Neočakávaná odpoveď | Dostali sme neočakávané dáta. Skús to znova. |
| 10 | invalidURL | Chyba konfigurácie | Niečo sa pokazilo s nastaveniami aplikácie. |
| 11 | context `.initialization` | Kvíz sa nepodarilo spustiť | Skontroluj pripojenie a skús to znova. |
| 12 | context `.submission` | Odpoveď sa nepodarilo odoslať | Skús odoslať odpoveď znova. |
| 13 | context `.recording` | Nahrávanie zlyhalo | Skús odpovedať znova. |
| 14 | context `.general` | Niečo sa pokazilo | Skús to znova. |
