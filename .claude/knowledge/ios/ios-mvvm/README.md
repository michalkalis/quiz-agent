# iOS MVVM Architecture

Use this knowledge when working with ViewModels, service layers, state management, or testing.

## Quick Reference

| Need | Reference |
|------|-----------|
| ViewModel pattern | [viewmodel-pattern.md](references/viewmodel-pattern.md) |
| Service layer design | [service-layer.md](references/service-layer.md) |
| State management | [state-management.md](references/state-management.md) |
| Mocking for tests | [mocking.md](references/mocking.md) |

## Decision Tree

### 1. Where does business logic go?
**ViewModel** - orchestrates services, manages UI state:
```swift
@MainActor
final class QuizViewModel: ObservableObject {
    @Published var state: QuizState = .idle
    private let networkService: NetworkServiceProtocol
}
```

### 2. Where does I/O go?
**Services** - network, audio, storage:
```swift
actor NetworkService: NetworkServiceProtocol { }

@MainActor
final class AudioService: AudioServiceProtocol { }
```

### 3. How do Views connect?
**@StateObject** for ownership, **@EnvironmentObject** for sharing:
```swift
struct ContentView: View {
    @StateObject private var viewModel = QuizViewModel()
}
```

### 4. How to test?
Protocol-based mocking:
```swift
#if DEBUG
final class MockNetworkService: NetworkServiceProtocol {
    var shouldFail = false
    var mockResponse: QuizSession?
}
#endif
```

## Architecture Layers

```
┌─────────────────────────────────────┐
│  Views (SwiftUI)                    │  UI only, no logic
├─────────────────────────────────────┤
│  ViewModels (@MainActor)            │  State, orchestration
├─────────────────────────────────────┤
│  Services (actor / @MainActor)      │  I/O, external systems
├─────────────────────────────────────┤
│  Models (struct, Codable)           │  Data structures
└─────────────────────────────────────┘
```

## State Machine Pattern

```swift
enum QuizState {
    case idle
    case loading
    case playing
    case recording
    case processing
    case finished
    case error
}

@MainActor
final class QuizViewModel: ObservableObject {
    @Published var state: QuizState = .idle

    func startQuiz() async {
        state = .loading
        do {
            session = try await networkService.createSession()
            state = .playing
        } catch {
            state = .error
        }
    }
}
```
