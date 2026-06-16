---
paths: ["apps/ios-app/**"]
---

# iOS Development Rules (Hangs)

- **Swift:** 6.0 (strict concurrency), **iOS:** 18.0+
- **Architecture:** MVVM with Service Layer
- **Voice-first** for hands-free driving use

## Knowledge Reference

Passive reference docs in `.claude/knowledge/ios/`:
swift-concurrency/, ios-mvvm/, ios-networking/, ios-audio/, ios-debugging/

## Project Structure

```
apps/ios-app/Hangs/Hangs/
├── Services/
│   ├── NetworkService.swift      # Actor - backend API
│   ├── AudioService.swift        # @MainActor - recording/playback
│   └── PersistenceStore.swift    # Unified persistence
├── ViewModels/
│   └── QuizViewModel.swift       # @MainActor - quiz state (decomposed into extensions)
├── Views/
│   ├── HomeView.swift
│   ├── QuestionView.swift
│   └── ResultView.swift
├── Models/
│   ├── Question.swift, QuizSession.swift, Evaluation.swift
└── Utilities/
    ├── Config.swift              # API URL from xcconfig
    └── Logging.swift             # os.Logger categories
```

## Schemes & Commands

| Scheme | API URL |
|--------|---------|
| Hangs-Local | `http://localhost:8002` |
| Hangs-Prod | `https://quiz-agent-api.fly.dev` |

| Task | Command |
|------|---------|
| Open project | `open apps/ios-app/Hangs/Hangs.xcodeproj` |
| Build (Local) | `cd apps/ios-app/Hangs && xcodebuild -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |
| Tests | `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` |

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

## Info.plist

Background audio mode enabled. Microphone usage description required.

## Mock Implementations

MockNetworkService, MockAudioService, MockPersistenceStore available for testing.
