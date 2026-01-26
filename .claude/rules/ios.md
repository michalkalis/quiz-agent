---
paths: apps/ios-app/**
---

# iOS Development Rules (CarQuiz Project)

## Project Overview

- **App:** CarQuiz - Voice-based trivia for hands-free use while driving
- **Path:** `apps/ios-app/CarQuiz/`
- **Swift:** 6.0 (strict concurrency), **iOS:** 18.0+
- **Architecture:** MVVM with Service Layer

## Knowledge Reference

For reusable iOS patterns, Claude will automatically consult `.claude/knowledge/ios/`:

| Topic | Location | When Used |
|-------|----------|-----------|
| Concurrency | `swift-concurrency/` | async/await, actors, @MainActor, Sendable |
| Architecture | `ios-mvvm/` | ViewModels, Services, state management |
| Networking | `ios-networking/` | URLSession, error handling, uploads |
| Audio | `ios-audio/` | AVFoundation, recording, playback, Bluetooth |
| Debugging | `ios-debugging/` | Build issues, network, audio problems |

These are passive reference docs (not slash commands). Claude reads them when contextually relevant.

## Project Structure

```
apps/ios-app/CarQuiz/CarQuiz/
├── Services/
│   ├── NetworkService.swift      # Actor - backend API
│   ├── AudioService.swift        # @MainActor - recording/playback
│   └── SessionStore.swift        # Persistence
├── ViewModels/
│   └── QuizViewModel.swift       # @MainActor - quiz state
├── Views/
│   ├── HomeView.swift
│   ├── QuestionView.swift
│   └── ResultView.swift
├── Models/
│   ├── Question.swift
│   ├── QuizSession.swift
│   └── Evaluation.swift
└── Utilities/
    └── Config.swift              # API URL configuration
```

## Build Commands

```bash
# Open in Xcode
open apps/ios-app/CarQuiz/CarQuiz.xcodeproj

# Build Local (localhost:8002)
cd apps/ios-app/CarQuiz && xcodebuild -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Build Production (Fly.io)
cd apps/ios-app/CarQuiz && xcodebuild -scheme CarQuiz-Prod -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Run tests
cd apps/ios-app/CarQuiz && xcodebuild test -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Environment Schemes

| Scheme | API URL | Use Case |
|--------|---------|----------|
| CarQuiz-Local | `http://localhost:8002` | Local development |
| CarQuiz-Prod | `https://quiz-agent-api.fly.dev` | Production testing |

Config is set via xcconfig files. See `README_ENVIRONMENTS.md` for details.

## API Endpoints

| Action | Method | Endpoint |
|--------|--------|----------|
| Create session | POST | `/api/v1/sessions` |
| Start quiz | POST | `/api/v1/sessions/{id}/start?audio=true` |
| Submit voice | POST | `/api/v1/voice/submit/{id}` (multipart) |
| Text input | POST | `/api/v1/sessions/{id}/input` |
| End session | DELETE | `/api/v1/sessions/{id}` |

## Models (Must Match Backend)

iOS Codable models must match backend Pydantic models:

| iOS Model | Backend Model | Location |
|-----------|---------------|----------|
| `QuizSession` | `QuizSession` | `packages/shared/quiz_shared/models/session.py` |
| `Question` | `Question` | `packages/shared/quiz_shared/models/question.py` |
| `Evaluation` | `Evaluation` | `apps/quiz-agent/app/evaluation/` |

**When backend changes:** Run `/verify-api` to check model sync.

## Key Implementation Notes

### NetworkService (Actor)
- 30s timeout for normal requests
- 120s timeout for voice submission (AI processing)
- Multipart upload for audio files

### AudioService (@MainActor)
- 16kHz sample rate for voice (smaller files)
- MP3 format for playback (not Opus)
- 100ms settle delay before recording

### QuizViewModel (@MainActor)
- State machine: idle → askingQuestion → recording → processing → showingResult → finished
- Auto-advance countdown after feedback
- Question snapshot for result display

## Info.plist Requirements

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
</array>

<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to record your answers.</string>
```

## Testing

```bash
# Unit tests
cd apps/ios-app/CarQuiz && xcodebuild test -scheme CarQuiz-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Mock implementations available:
- `MockNetworkService` - Configurable responses
- `MockAudioService` - Simulated recording/playback
- `MockSessionStore` - In-memory storage
