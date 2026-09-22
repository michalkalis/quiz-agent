---
paths: ["apps/ios-app/**"]
---

# iOS Development Rules (Hangs)

- **Swift:** 6.0 (strict concurrency), **iOS:** 26.0+
- **Architecture:** MVVM with Service Layer
- **Voice-first** for hands-free driving use

## Knowledge Reference

Passive reference docs in `.claude/knowledge/ios/`:
swift-concurrency/, ios-mvvm/, ios-networking/, ios-audio/, ios-debugging/

## Schemes & Commands

| Scheme | API URL |
|--------|---------|
| Hangs-Local | `http://localhost:8002` |
| Hangs-Prod | `https://quiz-agent-api.fly.dev` |

| Task | Command |
|------|---------|
| Open project | `open apps/ios-app/Hangs/Hangs.xcodeproj` |
| Build (Local) | `cd apps/ios-app/Hangs && xcodebuild -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Tests | `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO` (serialized — the suite is main-actor work on one process-wide serial executor, so in-process parallelism only starves it; see ios-ci.yml) |

**Tests never wait on real time (#180 track A).** Every quiz-path timer, backoff and deadline sleeps on the one injected `AnyClock<Duration>` (`QuizViewModel(clock:)`, `Fixtures.makeViewModel(clock:)`; pack view models and `SilenceDetectionService` take `clock:` too). A test that owns time builds the model with `AnyClock(TestClock())` and `await clock.advance(by:)` to the SHIPPED boundary — just before it (nothing fired) and past it — instead of shrinking durations. Use integer `.milliseconds(...)` at a boundary (a fractional `Duration` can land 1 as short). Scheduling-only waits use `pumpUntil` (turn-bounded), never `Task.sleep`. `AnyClock(ImmediateClock())` is unsafe on any submit path (the user-facing timeout would fire at once). Audio hardware settles in `QuizViewModel` and the audio mock stay real time by design.

## Accessibility identifiers (#180 track E)

The UI ships in sk/cs/en, so visible text is never a locator. `scripts/lint-a11y-ids.py` runs in `ios-ci.yml` and fails the PR on any miss; run it locally before pushing.

- **Every interactive control declares `.accessibilityIdentifier`** on its own modifier chain: Button, NavigationLink, Toggle, Picker, TextField, Menu (and each Menu item), Link, ShareLink, `.onTapGesture` hosts, and the project buttons (`HangsPrimaryButton`, `HangsSecondaryButton`, `HangsGhostButton`, `HangsNavChip`, `HangsSourceLink`, `HangsToggleRow`). An identifier on an enclosing container also counts (SwiftUI applies it to the subtree) — use that only for grouped rows, not to skip naming a button.
- **Naming:** `screen.element` in lowerCamel (`question.record`, `paywall.restore`), dynamic items `screen.element.<key>` (`home.language.sk`, `mcq.option.b`). Older `screen-element` ids exist and stay; don't rename them, don't add new hyphenated ones.
- **Reusable components leave the identifier to the call site** and say so with `// a11y-id: call-site` above the inner Button. A component that owns a fixed role (e.g. `QuestionSkipButton`) hardcodes its id instead.
- **Exemptions are explicit:** `// a11y-id: <reason>` on the element or the line above. Buttons inside `.alert` / `.confirmationDialog` are exempt automatically (UIAlertController drops identifiers); `Views/Debug/` and `#if DEBUG` regions are not linted.
- **UI tests (HangsUITests):** `app.<query>["…"]` literals must be identifiers; a label match is allowed only for system UI the app cannot tag (alert buttons, the StoreKit sheet), marked `// a11y-id: system alert` etc. Launch via `RSFlow.launch` / `RSFlow.baseLaunchArguments`, which pin the UI to English so those label matches and the verdict/hero content assertions don't depend on the simulator's language.
- **Definition of done for a new flow:** identifiers on its controls + a Page Object entry + a frozen RS scenario when the flow is user-visible (see `docs/testing/regression-scenarios.md`).

## Snapshots (#180 track F)

`HangsTests/HeroScreenSnapshotTests.swift` freezes Home / Question / Result / Paywall × sk/cs/en with swift-snapshot-testing; baselines are committed under `HangsTests/__Snapshots__/HeroScreenSnapshotTests/`.

- **Text contract (`.txt`) gates every CI run.** Every rendered `Text` resolved for the language plus every accessibility identifier, in tree order. A lost translation, identifier or element fails the PR with a readable diff. It does not depend on the simulator runtime.
- **Pixel snapshots (`.png`, 1×, default + accessibility Dynamic Type)** catch layout drift the contract cannot see. Rendering differs between iOS runtimes, so they run only on the runtime they were recorded on (`SnapshotBaseline.iosVersion`) and are visibly *skipped* elsewhere — today CI (iOS 26.2) skips them, the local iPhone 17 Pro simulator (iOS 26.5) runs them.
- **Never re-record to turn a red run green.** A diff is either a bug (fix the code) or an intentional UI change (a human looks at the new render, then re-records on purpose):
  `TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all xcodebuild test … -only-testing:HangsTests/HeroScreenSnapshotTests`, then run once more without the variable and commit the new files with the UI change.
- **Determinism:** fixed fixtures, `TestClock`, `debugSurfaces: false`, time-relative copy anchored 12½ days out. `String(localized:)` values built outside SwiftUI stay in the process language; only `Text` keys switch with `\.locale`.
- Adding a hero-level screen = add a `HeroScreen` case; a new language = a `HeroLanguage` case; both re-record only their own files.

## Definition of done for an agent (#180 track H)

- **A new or changed user-visible flow** ships with accessibility identifiers on its controls (lint enforces), a Page Object entry and a frozen RS scenario in `HangsUITests` (`docs/testing/regression-scenarios.md`); a new hero-level screen also joins the snapshot set above.
- **A PR is done when** `xcodebuild test` is green on CI — unit + ViewInspector contracts + text snapshots + the RS suite — with no test skipped that the change touches, and any snapshot diff was re-recorded deliberately, never to pass.
- **Stateful bugs (timers, audio, purchases, quota) are reproduced as deterministic unit tests first** (injected clock, posted notifications, StoreKit lifecycle mocks); the RS suite and `/regression` are for flows, not for hunting state bugs.
- **TestFlight is for humans:** visual judgement on device and a real purchase. A state or regression bug found in TestFlight means a missing test at one of the layers above — add it with the fix.

## Simulator driving & XcodeBuildMCP token cost

XcodeBuildMCP runs locally (no LLM of its own), but its `snapshot_ui` returns the **full accessibility tree as large JSON** and `screenshot` returns an **image** — every such call lands in whatever session drives it and stays there. Driving the simulator directly from the main session (Opus) is the single biggest iOS token sink. So:

- **Never drive the simulator from the main session.** Any task that taps/snapshots/screenshots the running app — an ad-hoc UI check, a click-through, or a regression run — is delegated to the **`ios-ui-driver`** subagent (model `sonnet`), which absorbs the snapshot/screenshot payloads in its own context and returns only a few-line conclusion. `/regression` already routes through it.
- **Build & unit-test via the shell `xcodebuild` commands above** (pipe `| tail`), or the `ios-tester` agent (haiku) — not MCP `build_sim`/`test_sim`, which dump the whole log into context. Use MCP `build_sim`/`clean` only inside a procedure that prescribes them (the regression skill).
- **Screenshot only for a genuine *visual* judgement** (color, layout, clipping). For state/element-presence use the accessibility tree (`wait_for_ui`/`snapshot_ui`). Never screenshot just to "show" the founder — he checks his own simulator.

## Localization (#56)

All user-facing text lives in `Localizable.xcstrings` (English = source key). When adding strings:
- **SwiftUI views:** use a string literal — `Text("Start")`, `Button`, `.navigationTitle`, `Label`. These are `LocalizedStringKey` and the compiler auto-extracts them. Never pass a runtime `String` where a literal belongs.
- **Custom component static-text params:** type them `LocalizedStringKey` (not `String`) so call-site literals extract. Pass interpolation as a literal — `title: "Unlock — \(price)"` — never `String(localized:)` (a `String` won't convert to `LocalizedStringKey`).
- **Non-view code** (ViewModels, Services, models, error enums) and `String`-typed contexts: wrap with `String(localized: "…", comment: "…")` — never a bare literal.
- **Non-localizable display** (brand wordmark, raw values, `"\(n)%"`, SF-symbol names): use `Text(verbatim:)` so it's excluded from the catalog.
- Casing: prefer `.textCase(.uppercase)` (display modifier) over `.uppercased()` (string mutation). Note: ViewInspector `find(text:)` then matches the source key, not the uppercased output.

## API

Endpoints are authoritative in backend OpenAPI spec — `curl http://localhost:8002/openapi.json`. Run `/verify-api` to confirm iOS Codable structs match Pydantic models.

## Models (Must Match Backend)

| iOS Model | Backend Model | Location |
|-----------|---------------|----------|
| `QuizSession` | `QuizSession` | `packages/shared/quiz_shared/models/session.py` |
| `Question` | `Question` | `packages/shared/quiz_shared/models/question.py` |
| `Evaluation` | `Evaluation` | `apps/quiz-agent/app/evaluation/` |

## Key Implementation Details

- **NetworkService:** 30s timeout normal, 120s for voice (AI processing)
- **AudioService:** 16kHz sample rate, MP3 playback, 100ms settle delay
- **QuizViewModel:** State machine via `transition(to:caller:)` with legal transition table
  States: idle → askingQuestion → recording → processing → showingResult → finished

## Verification Altitude (#57)

Tests — and the autonomous loop's gate — verify **the right flow and correct states, not design fidelity.** Write tests at this altitude:

- **Gate on flow, state-machine correctness, and presence of expected UI elements.** Assert the user can click through the flow and the expected buttons/text/elements are present and the state machine reaches the right state. This is what HangsTests already does (ViewInspector `find(text:)`/`find(button:)` structure assertions + `.stableDump`/`.dump` textual state snapshots + the `HangsUITests` RS click-through scenarios) — keep tests there.
- **Do NOT gate on pixel / `.pen` design fidelity.** The screenshot-verify-against-`docs/design/frames/` step (#44/#52) is a *separate, non-gating* visual check, not part of `xcodebuild test`. The design is still moving, so 1:1-with-`.pen` would trip on cosmetic drift. It stays on-demand / human until the design stabilizes.
- **A `.stableDump`/`.dump` snapshot diff from an intentional UI change is a re-record signal, not a hard block.** Surface it for human re-record sign-off; don't silently "fix" it or hard-fail the run on it.

## UI Verification

Any change that can affect the UI (layout, colors, visibility, spacing) requires a screenshot-verify step before the task is considered done — see `docs/testing/screenshot-verify-procedure.md`. This enforces CLAUDE.md rule #2 "Fail loud": '"tests pass" is wrong if … UI wasn't verified'. Per **Verification Altitude** above, this screenshot-verify is a non-gating human/on-demand check — it does not block the autonomous merge gate.

