# Issue #56 — iOS text localization (String Catalog)

**Triage:** refactor · queued
**Status:** Plan written 2026-06-12; atomized into 9 Ralph `- [ ]` tasks + 1 `- [HUMAN]` 2026-06-13 (see task list below). Queued for the next overnight run. English is the source language; Slovak and other languages come later as pure translation work in the catalog.

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
- **Compiler extraction**: with `SWIFT_EMIT_LOC_STRINGS = YES` (currently `NO`), Xcode auto-populates the catalog from SwiftUI `Text("…")`, `Button("…")`, `Label`, `navigationTitle`, etc. — these literals are already `LocalizedStringKey`, so most view code needs **no rewrite**, just a build.
- Non-view code (ViewModels, Services, error enums, model display names) uses `String(localized:comment:)` explicitly.
- **Key strategy: English source text as the key** (Apple default). This keeps view code readable, lets compiler extraction work, and — critically — keeps ViewInspector `find(text:)` assertions passing, because the resolved English value equals the literal. Semantic keys (`"question.skip.button"`) were considered and rejected: they'd force rewriting all 56 `find(text:)` assertions and every `Text()` call for no benefit at our scale (~130–150 strings).

Rejected alternatives: legacy `.strings`/`.stringsdict` (superseded, no plural editor, no staleness tracking); third-party SwiftGen/L10n enums (extra build tooling, fights compiler extraction, overkill for a solo project).

## Current state (analysis 2026-06-12)

- **Zero localization infra**: no catalogs, no `.lproj`, no `NSLocalizedString`/`String(localized:)` anywhere. `knownRegions = (en, Base)`, `SWIFT_EMIT_LOC_STRINGS = NO`.
- **~130–150 distinct client-side strings** across ~25 files. Top offenders: `AppErrorModel.swift` (14 title+description pairs), `OnboardingView` (~18), `QuestionView` (~14), `ResultView` (~12), `SettingsView` (~12), `AnswerConfirmationView` (~10), `CompletionView`, `PaywallView`, `MinimizedQuizView`, `AudioDevicePickerView`.
- **`AppErrorModel.swift` is entirely in Slovak** — the only non-English copy in the app. Error screens show Slovak regardless of language. Must become English source text first.
- **Display-name duplication**: category/difficulty display names exist in both `Utilities/Config.swift` and `Models/QuizSettings.swift` — single-source before extraction so each string is in the catalog once.
- **Tests**: snapshot tests use `.stableDump` (view-model state, not rendered text) → safe. 56 ViewInspector `find(text:)` assertions match English literals → safe **only** with the English-as-key strategy (verify in 56.2 pilot).
- **Backend content is out of scope client-side**: question text, answers, feedback, evaluation come from the API already localized via `session.language`. Category display names shown in UI are client-side and ARE in scope.
- **Intentionally locale-fixed code — do not touch**: `MCQTranscriptMatcher` and `LogEntry` use `en_US_POSIX` on purpose (ASCII matching, log timestamps).

## Tasks

### Ralph atomic task list (run in order; full detail in §56.x below)

All source paths below are under `apps/ios-app/Hangs/` (e.g. `apps/ios-app/Hangs/Hangs/Models/AppErrorModel.swift`).
Build + test from `apps/ios-app/Hangs` (scheme `Hangs-Local`); the XcodeBuildMCP server is attached for `build_sim`/`xcodebuild`.

Pick the **first unchecked `- [ ]`** each iteration. **Hard gate at 56.2** — if the
pilot test fails, append a `## BLOCKER` note and stop; do NOT proceed to mass extraction.
Each task must end with a green build + its named tests before being checked off.

- [x] **56.1a** — Rewrite `AppErrorModel.swift` copy Slovak→English (14 title+description pairs); keep the Slovak in the appendix below. Verify `AppErrorModelTests` pass + app builds. (§56.1)
- [ ] **56.1b** — Single-source the duplicated category/difficulty display names between `Config.swift` and `QuizSettings.swift` (the model is the owner). Build + tests green. (§56.1)
- [ ] **56.2** — Add `Localizable.xcstrings` to the Hangs target; set `SWIFT_EMIT_LOC_STRINGS = YES` on the **app target only** (not test targets). Build → confirm compiler extraction populates the catalog. **PILOT GATE:** run `OnboardingViewInspectorTests` + one snapshot suite; if `find(text:)` breaks, append a `## BLOCKER` note and STOP — do not start 56.3. (§56.2)
- [ ] **56.3a** — Convert `QuizViewModel` (+`+Recording`/`+Audio`) user-facing strings + `NetworkService.NetworkError.errorDescription` to `String(localized:comment:)`. Build + targeted tests green. (§56.3)
- [ ] **56.3b** — Convert display-name computed properties to `String(localized:)`: categories/difficulties (post-56.1b), `AudioMode`, `Language`, `ListeningPill.Mode.copy`, `HangsResultKind.label`, plus `AppErrorModel` (post-56.1a English copy). Build + tests green. (§56.3)
- [ ] **56.3c** — Convert accessibility labels/hints + interpolated/plural strings to `String(localized:)` with `comment:`; keep interpolation inside the string; add plural variants in the catalog editor; exclude debug-only UI via `Text(verbatim:)`. Build + tests green. (§56.3)
- [ ] **56.4** — File-by-file sweep of `Views/**` + `Models|Services|ViewModels|Utilities` against the inventory; `Text(verbatim:)` for brand/raw/non-localizable; catalog hygiene (mark "Don't translate", add ambiguous-key comments); add the `String(localized:)` guardrail one-liner to `.claude/rules/ios.md`. (§56.4)
- [ ] **56.5** — Full unit suite on mba (≈363 tests; expect only known pre-existing snapshot fails). Confirm the app still builds + runs in English. (§56.5)
- [HUMAN] **56.6** — Pseudo-localization visual smoke (Xcode "Double-Length Pseudolanguage") across every screen; eyeball for missed literals. Visual — human-only.

### 56.1 Pre-work (no localization yet)
- Rewrite `AppErrorModel.swift` copy Slovak → English (14 title+description pairs). The Slovak text becomes the first `sk` translation when that language lands — keep it in the issue file appendix below.
- Single-source the duplicated category/difficulty display names between `Config.swift` and `QuizSettings.swift` (pick one owner, likely the model).
- Verify: `AppErrorModelTests` still pass (they assert non-emptiness, not Slovak values); app builds.

### 56.2 Infrastructure + pilot
- Add `Localizable.xcstrings` to the Hangs target.
- Set `SWIFT_EMIT_LOC_STRINGS = YES` on the app target (leave test targets as-is).
- Build → confirm compiler extraction populates the catalog from existing SwiftUI literals.
- **Pilot gate**: run `OnboardingViewInspectorTests` + one snapshot suite to confirm the English-as-key assumption holds (find(text:) still passes). If it doesn't, stop and re-plan the test strategy before mass extraction.

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
- Full test suite on mba (363 tests; expect only the 3 known pre-existing snapshot fails from #54).
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

Preserve from `Hangs/Models/AppErrorModel.swift` @ d5ac9c0 before 56.1 rewrites it: 14 pairs incl. „Akcia bola zrušená", „Nie je internetové pripojenie", „Čas vypršal", „Denný limit dosiahnutý", „Relácia vypršala", „Chyba servera", „Príliš veľa požiadaviek", „Neočakávaná odpoveď", „Chyba konfigurácie", „Kvíz sa nepodarilo spustiť", „Odpoveď sa nepodarilo odoslať", „Nahrávanie zlyhalo", „Niečo sa pokazilo" (+ descriptions in file history).
