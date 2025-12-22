# Quiz Agent - Monorepo

AI-powered quiz platform with voice-based interaction. Designed for hands-free trivia while driving.

## Repository Structure

```
quiz-agent/
├── apps/
│   ├── quiz-agent/          # FastAPI backend (Python)
│   ├── question-generator/  # Question generation service (Python)
│   ├── web-ui/             # Web interface (Next.js/React)
│   └── ios-app/            # iOS app (Swift 6, SwiftUI) - IN PROGRESS
├── packages/
│   └── shared/             # Shared Python models and utilities
└── course-examples/        # Course materials and examples
```

## Apps Overview

### Quiz Agent Backend (apps/quiz-agent/)
FastAPI REST API providing:
- Session management (in-memory with TTL)
- Voice transcription (Whisper API)
- AI-powered answer evaluation (GPT-4)
- Text-to-speech audio generation (OpenAI TTS)
- RAG-based question retrieval (ChromaDB)

**Tech:** Python 3.11+, FastAPI, ChromaDB, OpenAI API

### Question Generator (apps/question-generator/)
Admin tool for generating and managing quiz questions.

**Tech:** Python 3.11+, FastAPI, ChromaDB

### Web UI (apps/web-ui/)
Web-based interface for quiz management and question review.

**Tech:** Next.js, React, TailwindCSS

### iOS App (apps/ios-app/) - **IN PROGRESS**

Native iOS application for voice-based trivia quizzes designed for hands-free use while driving.

#### Tech Stack
- **Platform:** iOS 18.0+
- **Language:** Swift 6.0
- **UI:** SwiftUI only
- **Architecture:** MVVM with Service Layer
- **Backend:** Consumes quiz-agent REST API

#### Key Features
- Voice recording and submission
- Text-to-speech question playback
- Background audio support (continues when app backgrounded)
- Session persistence via UserDefaults
- Simple session management (no authentication for MVP)

#### Project Structure
```
apps/ios-app/
└── QuizAgent/
    ├── Models/          # Codable structs matching API
    ├── Services/        # NetworkService, AudioService, SessionStore
    ├── ViewModels/      # QuizViewModel with business logic
    ├── Views/           # SwiftUI views
    └── Resources/       # Assets, Info.plist
```

#### Running the iOS App
1. Open `apps/ios-app/QuizAgent.xcodeproj` in Xcode 16+
2. Select iOS 18+ simulator or device
3. Update `Config.swift` with backend API URL (default: localhost:8002)
4. Build and run (Cmd+R)

#### Development Notes
- Requires microphone permissions (configured in Info.plist)
- Background audio configured via AVAudioSession
- Uses async/await for all networking
- Actor-based NetworkService for thread safety
- @MainActor AudioService (AVFoundation requires main thread)

#### API Integration
See backend API documentation at `apps/quiz-agent/README.md` for endpoint details.

Key endpoints:
- `POST /api/v1/sessions` - Create session
- `POST /api/v1/sessions/{id}/start?audio=true` - Start quiz
- `POST /api/v1/voice/submit/{id}` - Submit voice answer
- `GET /api/v1/tts/feedback/{result}` - Get feedback audio

## Shared Packages

### packages/shared/
Common Python models and utilities shared across backend services:
- `quiz_shared.models.session` - QuizSession, Participant
- `quiz_shared.models.question` - Question model
- `quiz_shared.models.participant` - Participant model

## Getting Started

Each app has its own README with detailed setup instructions. See:
- `apps/quiz-agent/README.md` - Backend API
- `apps/question-generator/README.md` - Question generator
- `apps/web-ui/README.md` - Web interface
- `apps/ios-app/README.md` - iOS app (to be created)

## Development Workflow

This is a **monolithic repository (monorepo)** approach, allowing:
- Code sharing between services
- Unified version control
- Cross-app development efficiency
- Shared ChromaDB instance across all services

## Environment Setup

**Backend (Python):**
```bash
# Install dependencies
uv pip install -e apps/quiz-agent
uv pip install -e apps/question-generator

# Run services
cd apps/quiz-agent
uvicorn app.main:app --reload --port 8002
```

**iOS App:**
```bash
# Open in Xcode
open apps/ios-app/QuizAgent.xcodeproj

# Or use xcodebuild
cd apps/ios-app
xcodebuild -scheme QuizAgent -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Architecture Philosophy

- **Backend:** FastAPI with in-memory session management (simple, fast, scalable)
- **Frontend:** Client-agnostic API design (works with iOS, web, terminal, TV apps)
- **AI Integration:** OpenAI for transcription, evaluation, and TTS
- **Storage:** ChromaDB for semantic question search, SQLite for ratings
- **iOS:** Native SwiftUI with MVVM (no over-engineering, focus on simplicity)

## Deployment

**Production API:**
- URL: https://quiz-agent-api.fly.dev
- Features: TTS with Opus audio, 3-tier caching, iOS-ready endpoints
- Hosting: Fly.io with persistent volumes (3GB)
- Estimated cost: ~$110/mo at 100 daily users

## License

MIT
