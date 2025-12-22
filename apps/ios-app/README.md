# Quiz Agent iOS App

Voice-first, hands-free iOS trivia quiz application for safe use while driving.

## Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 16.0 or later
- iOS 18.0+ device or simulator
- Quiz Agent backend running (see `../quiz-agent/README.md`)

## Quick Start

### 1. Create Xcode Project

**Important:** This must be done through Xcode GUI to ensure proper Swift 6 and iOS 18 configuration.

1. Open Xcode 16+
2. File → New → Project
3. Choose **iOS → App**
4. Configure:
   - Product Name: `QuizAgent`
   - Team: Your development team
   - Organization Identifier: `com.yourcompany` (or your identifier)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: None (we'll use UserDefaults)
   - Include Tests: ✅ Yes

5. Save location: Select `apps/ios-app/` folder (this directory)
6. **Important Settings:**
   - Go to Project Settings → Build Settings
   - Search for "Swift Language Version"
   - Set to **Swift 6**
   - Go to General → Deployment Info
   - Set Minimum Deployment to **iOS 18.0**

### 2. Configure Project

After creating the project, you need to:

1. **Enable Background Audio:**
   - Select project in navigator
   - Go to target → Signing & Capabilities
   - Click "+ Capability"
   - Add "Background Modes"
   - Check "Audio, AirPlay, and Picture in Picture"

2. **Add Microphone Permission:**
   - Open `Info.plist`
   - Add new row: `NSMicrophoneUsageDescription`
   - Value: `We need microphone access to record your quiz answers hands-free.`

3. **Copy Source Files:**
   - The source files in `QuizAgent/` folder need to be added to your Xcode project
   - Right-click on project in navigator → Add Files to "QuizAgent"
   - Select the folders: Models, Services, ViewModels, Views

### 3. Run the App

1. Select a simulator (iPhone 15 Pro or newer recommended)
2. Press Cmd+R to build and run
3. Grant microphone permission when prompted

## Project Structure

```
QuizAgent/
├── Models/              # Codable data models matching backend API
│   ├── Session.swift
│   ├── Question.swift
│   ├── QuizResponse.swift
│   ├── Evaluation.swift
│   └── AudioInfo.swift
│
├── Services/           # Business logic services
│   ├── NetworkService.swift    # REST API client (actor)
│   ├── AudioService.swift      # Recording/playback (@MainActor)
│   └── SessionStore.swift      # UserDefaults persistence
│
├── ViewModels/         # View state management
│   └── QuizViewModel.swift     # Core quiz flow logic
│
├── Views/              # SwiftUI views
│   ├── QuizAgentApp.swift      # App entry point
│   ├── ContentView.swift       # Main navigation
│   ├── HomeView.swift          # Welcome screen
│   ├── QuestionView.swift      # Quiz question screen
│   ├── ResultView.swift        # Answer evaluation
│   ├── CompletionView.swift    # Session summary
│   └── Components/
│       ├── RecordButton.swift
│       └── ProgressBar.swift
│
├── Utilities/          # Helper extensions and utilities
│   ├── Config.swift            # API base URL configuration
│   └── Extensions.swift
│
└── Resources/          # Assets, plists, etc.
    └── Assets.xcassets
```

## Configuration

### API Endpoint

Update `Utilities/Config.swift` to point to your backend:

```swift
enum Config {
    static var apiBaseURL: String {
        #if DEBUG
        return "http://localhost:8002"  // Local development
        #else
        return "https://your-api.com"   // Production
        #endif
    }
}
```

### Backend Setup

Ensure the quiz-agent backend is running:

```bash
cd ../quiz-agent
uvicorn app.main:app --reload --port 8002
```

The API should be accessible at `http://localhost:8002/api/v1/health`

## Architecture

**Pattern:** MVVM (Model-View-ViewModel) with Service Layer

- **Models:** Pure Swift structs with Codable conformance
- **Services:** Protocol-based services (NetworkService, AudioService, SessionStore)
- **ViewModels:** Observable business logic with @Published properties
- **Views:** Declarative SwiftUI views observing ViewModel state

**Key Design Decisions:**
- Swift 6 with strict concurrency
- Actor for NetworkService (thread-safe)
- @MainActor for AudioService (AVFoundation requirement)
- Async/await for all networking
- Background audio support for driving use case

## Testing

### Unit Tests

```bash
# Run all tests
xcodebuild test -scheme QuizAgent -destination 'platform=iOS Simulator,name=iPhone 15'

# Or use Xcode: Cmd+U
```

Tests are located in `QuizAgentTests/`

### Manual Testing Checklist

- [ ] Create new quiz session
- [ ] Record voice answer
- [ ] Hear question audio playback
- [ ] Hear feedback audio (correct/incorrect)
- [ ] Complete full 10-question quiz
- [ ] Resume session after app restart
- [ ] Background audio continues when app backgrounded
- [ ] Handle phone call interruption gracefully
- [ ] Microphone permission request flow

## Development Workflow

1. **Start Backend:** `cd ../quiz-agent && uvicorn app.main:app --reload --port 8002`
2. **Open Xcode:** `open QuizAgent.xcodeproj`
3. **Run:** Cmd+R
4. **Test:** Cmd+U

## Troubleshooting

### "Backend Connection Failed"
- Ensure quiz-agent backend is running on port 8002
- Check `Config.swift` has correct URL
- For iOS Simulator, use `http://localhost:8002` (not 127.0.0.1)

### "Opus Audio Not Playing"
- iOS 18+ supports Opus natively
- Test on physical device if simulator fails
- Fallback: Request MP3 from backend with `?audio_format=mp3`

### "Microphone Permission Denied"
- Go to iOS Settings → Privacy → Microphone → QuizAgent
- Enable permission
- Restart app

## Deployment

### TestFlight

1. Archive: Product → Archive
2. Upload to App Store Connect
3. Add to TestFlight build
4. Invite testers

### App Store

See `docs/app-store-submission.md` for full checklist

## License

MIT
