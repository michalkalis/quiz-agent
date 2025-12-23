# Quiz Agent - Monorepo

AI-powered quiz platform with voice-based interaction. Designed for hands-free trivia while driving.

## Development Guidelines

For detailed development rules, see:
- **Backend Development:** @.claude/rules/backend.md (Python/FastAPI rules)
- **iOS Development:** @.claude/rules/ios.md (Swift/SwiftUI rules)
- **Shared Standards:** @.claude/rules/shared.md (Git workflow, testing, API contracts)

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

**Tech:** iOS 18.0+, Swift 6.0, SwiftUI, MVVM with Service Layer

**Key Features:**
- Voice recording and submission with background audio support
- Text-to-speech question playback
- Session persistence via UserDefaults
- No authentication required (MVP)

**Quick Start:**
```bash
open apps/ios-app/CarQuiz.xcodeproj
# Update Config.swift with backend URL, then Cmd+R
```

**Important:** Models must be Codable and match backend Pydantic models. See @.claude/rules/ios.md for detailed development guidelines.

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

This is a **monolithic repository (monorepo)** approach, providing:
- **API Contract Management:** OpenAPI spec as single source of truth
- **Atomic Commits:** Update backend + iOS in single PR to prevent breakage
- **Unified Version Control:** All apps versioned together
- **Shared Dependencies:** Python packages in `packages/shared/`
- **Cross-App Development:** Easy visibility into how services interact

## Architecture Philosophy

- **Backend:** FastAPI with in-memory session management (simple, fast, scalable)
- **Frontend:** Client-agnostic API design (works with iOS, web, terminal, TV apps)
- **AI Integration:** OpenAI for transcription, evaluation, and TTS
- **Storage:** ChromaDB for semantic question search, SQLite for ratings
- **iOS:** Native SwiftUI with MVVM (no over-engineering, focus on simplicity)

## API Contracts Between Backend & iOS

**Critical:** The iOS app and web UI consume the FastAPI backend. Maintain API contract integrity:

### OpenAPI-Driven Development
- Backend FastAPI auto-generates OpenAPI spec at `/docs` and `/openapi.json`
- iOS uses Swift OpenAPI Generator (build-time code generation)
- Web UI uses TypeScript generator (when implemented)
- Single source of truth: OpenAPI spec, not manual model synchronization

### When Making API Changes
1. Update Pydantic models in `apps/quiz-agent/` or `packages/shared/`
2. Verify OpenAPI spec updated: `curl http://localhost:8002/openapi.json`
3. Test endpoint manually via `/docs`
4. **Verify iOS still builds** (models must match Codable structs)
5. Prefer atomic commits: update backend + iOS in same PR

### Breaking Changes
- Use API versioning (`/api/v2/`) for breaking changes
- Add deprecation warnings before removing endpoints
- Update all clients atomically when possible

## Common Development Commands

### Backend
```bash
# Start backend API
cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002

# Start question generator
cd apps/question-generator && uvicorn app.main:app --reload --port 8003

# Run tests
cd apps/quiz-agent && pytest tests/ -v

# Install dependencies
uv pip install -e apps/quiz-agent
uv pip install -e packages/shared
```

### iOS
```bash
# Open in Xcode
open apps/ios-app/CarQuiz.xcodeproj

# Build from command line
cd apps/ios-app && xcodebuild -scheme CarQuiz -destination 'platform=iOS Simulator,name=iPhone 15'

# Run tests
cd apps/ios-app && xcodebuild test -scheme CarQuiz -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Cross-Platform
```bash
# Download OpenAPI spec for iOS client generation
curl http://localhost:8002/openapi.json > apps/ios-app/openapi.yaml
```

## Deployment

**Production API:**
- URL: https://quiz-agent-api.fly.dev
- Features: TTS with Opus audio, 3-tier caching, iOS-ready endpoints
- Hosting: Fly.io with persistent volumes (3GB)
- Estimated cost: ~$110/mo at 100 daily users

## License

MIT
