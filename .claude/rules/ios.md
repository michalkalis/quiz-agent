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

## Info.plist

Background audio mode enabled. Microphone usage description required.

## Mock Implementations

MockNetworkService, MockAudioService, MockPersistenceStore available for testing.
