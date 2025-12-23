---
paths: apps/ios-app/**
---

# iOS Development Rules

## Swift/SwiftUI Standards

- **Swift Version:** 6.0 (strict concurrency checking enabled)
- **iOS Minimum:** 18.0+
- **UI Framework:** SwiftUI only (no UIKit)
- **Architecture:** MVVM with Service Layer pattern
- **Concurrency:** async/await for all networking and I/O operations
- **Type Safety:** Leverage Swift's type system, avoid force unwrapping (!)

## Key Architecture Patterns

### Service Layer

**NetworkService** (apps/ios-app/CarQuiz/CarQuiz/Services/NetworkService.swift)
- Actor-based for thread safety
- Handles all backend API communication
- Uses URLSession with async/await
- Error handling: throws custom errors with detailed messages

**AudioService** (apps/ios-app/CarQuiz/CarQuiz/Services/AudioService.swift)
- @MainActor (AVFoundation requires main thread)
- Manages microphone recording (AVAudioRecorder)
- Handles audio playback (AVAudioPlayer)
- Background audio: Configured via AVAudioSession

**SessionStore** (apps/ios-app/CarQuiz/CarQuiz/Services/SessionStore.swift)
- ObservableObject for state management
- Persists session ID via UserDefaults
- Simple key-value storage (no CoreData needed for MVP)

### View Models

**QuizViewModel** (apps/ios-app/CarQuiz/CarQuiz/ViewModels/QuizViewModel.swift)
- @MainActor (updates UI state)
- Coordinates between NetworkService and AudioService
- Manages quiz flow state machine
- Single source of truth for quiz state

### Models (Codable)

All models must be Codable and match backend Pydantic models:
- `Session.swift` - Session ID and metadata
- `Question.swift` - Quiz question structure
- `QuizResponse.swift` - Response from backend
- `Evaluation.swift` - Answer evaluation result
- `AudioInfo.swift` - Audio metadata

**Critical:** When backend updates Pydantic models, verify these Codable structs still match.

## Configuration

**Config.swift** (apps/ios-app/CarQuiz/CarQuiz/Utilities/Config.swift)
- Controls backend API URL
- Default: `http://localhost:8002` for development
- Production: `https://quiz-agent-api.fly.dev`
- Change this when testing against production API

## Background Audio Support

**Info.plist Configuration:**
- `UIBackgroundModes` includes `audio`
- `NSMicrophoneUsageDescription` required for recording

**AVAudioSession Setup:**
```swift
try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default)
try AVAudioSession.sharedInstance().setActive(true)
```

This allows:
- Audio playback when app is backgrounded
- Microphone recording during active use
- Integration with CarPlay (future)

## Common Development Commands

### Open in Xcode
```bash
open apps/ios-app/CarQuiz.xcodeproj
```

### Build from Command Line
```bash
cd apps/ios-app
xcodebuild -scheme CarQuiz -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Run Tests
```bash
cd apps/ios-app
xcodebuild test -scheme CarQuiz -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Clean Build Folder
```bash
cd apps/ios-app
xcodebuild clean -scheme CarQuiz
```

## Network Error Handling

### Timeouts
- Default: 30 seconds for API requests
- Longer timeout for audio transcription (60 seconds)
- Configurable via URLRequest.timeoutInterval

### Retry Logic
- Exponential backoff for transient failures
- Maximum 3 retries
- Don't retry on 4xx client errors (only 5xx or network errors)

### Session Loss Handling
- If backend returns 404 for session ID, prompt user to create new session
- SessionStore.clearSession() removes stale session ID
- User redirected to HomeView to start fresh

### Decoding Errors
- Log full response body when JSON decoding fails
- Include URL and status code in error messages
- See NetworkService.swift for detailed error logging

## API Integration

### Endpoint Usage

**Create Session:**
```swift
POST /api/v1/sessions
Response: { "session_id": "uuid" }
```

**Start Quiz:**
```swift
POST /api/v1/sessions/{id}/start?audio=true
Response: { "question": {...}, "audio_url": "..." }
```

**Submit Voice Answer:**
```swift
POST /api/v1/voice/submit/{id}
Content-Type: multipart/form-data
Body: audio file (MP3 or M4A)
Response: { "evaluation": {...}, "audio_url": "..." }
```

**Get Next Question:**
```swift
POST /api/v1/sessions/{id}/next?audio=true
Response: { "question": {...}, "audio_url": "..." }
```

### API Contract Validation

When backend API changes:
1. Download updated OpenAPI spec: `curl http://localhost:8002/openapi.json > openapi.yaml`
2. Verify Codable models match response structure
3. Update models if needed
4. Run tests to ensure decoding works
5. Test against real backend (not just mocks)

## Swift OpenAPI Generator Integration

**Goal:** Auto-generate type-safe client code from backend OpenAPI spec

### Setup (To Be Implemented)
```swift
// Package.swift or Xcode project dependencies
.package(url: "https://github.com/apple/swift-openapi-generator", from: "1.0.0"),
.package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
.package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
```

### Build-Time Generation
- OpenAPI spec placed in project directory (openapi.yaml)
- Xcode build plugin generates Swift code automatically
- Generated code NOT committed to git (similar to .gitignore)
- Always in sync with backend API

### Benefits
- Type-safe API calls
- Automatic Codable conformance
- Compile-time verification of API contracts
- No manual model synchronization

## Threading and Concurrency

### Main Actor
- All UI updates must be on main thread
- ViewModels: @MainActor
- AudioService: @MainActor (AVFoundation requirement)

### Actor Isolation
- NetworkService: actor (not @MainActor)
- Can be called from any context
- Ensures thread-safe access to internal state

### Async/Await Best Practices
```swift
// Good: Structured concurrency
Task {
    let result = await networkService.fetchData()
    await MainActor.run {
        self.data = result
    }
}

// Bad: Nested completion handlers
networkService.fetchData { result in
    DispatchQueue.main.async {
        self.data = result
    }
}
```

## Testing Guidelines

### Unit Tests
- Test ViewModels in isolation
- Mock NetworkService and AudioService
- Use protocols for dependency injection

### UI Tests
- Test critical user flows (session creation, answering questions)
- Use XCUITest framework
- Run on simulator, not required on real device for MVP

### Integration Tests
- Test against local backend (localhost:8002)
- Verify end-to-end flows
- Mock OpenAI API responses in backend (don't hit real API in tests)

## Code Style Guidelines

### SwiftUI Views
- Keep views under 200 lines (extract subviews)
- Use @State for local state, @StateObject/@ObservedObject for external state
- Prefer explicit types over type inference for clarity

### Naming Conventions
- ViewModels: `{Feature}ViewModel` (e.g., QuizViewModel)
- Services: `{Purpose}Service` (e.g., NetworkService)
- Views: `{Feature}View` (e.g., QuestionView)

### Error Handling
```swift
// Good: Specific error types
enum NetworkError: Error {
    case invalidResponse
    case decodingFailed(Error)
    case sessionNotFound
}

// Bad: Generic errors
throw NSError(domain: "com.app", code: -1, userInfo: nil)
```

## Dependencies and Package Management

### Swift Package Manager (SPM)
- Preferred for dependencies
- Add via Xcode: File → Add Package Dependencies
- Avoid using CocoaPods or Carthage for this project

### Current Dependencies
- None (all features use iOS SDK)
- Future: Swift OpenAPI Generator packages

## Debugging Tips

### Network Debugging
- Enable Network Link Conditioner for slow network testing
- Use Charles Proxy or Proxyman to inspect HTTP traffic
- Log URLRequest and URLResponse in NetworkService

### Audio Debugging
- Test microphone permissions in Settings app
- Verify AVAudioSession configuration
- Check audio file format (should be MP3 or M4A)

### Build Issues
- Clean build folder: Cmd+Shift+K
- Delete derived data: ~/Library/Developer/Xcode/DerivedData/
- Reset simulators if audio/permissions broken

## Production Considerations

### Security
- No hardcoded API keys (backend handles OpenAI)
- Use HTTPS in production (Config.swift URL)
- Validate SSL certificates (default URLSession behavior)

### Performance
- Lazy loading for large lists (not needed for MVP)
- Cache audio files locally (future enhancement)
- Monitor memory usage with Instruments

### App Store Submission
- Privacy manifest required (iOS 17+)
- Microphone usage description in Info.plist
- Test on real device before submission
- Beta testing via TestFlight recommended
