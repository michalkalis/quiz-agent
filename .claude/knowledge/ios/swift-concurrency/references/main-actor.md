# @MainActor Patterns

## Core Concept
`@MainActor` ensures code runs on the main thread, required for UI updates in SwiftUI/UIKit. It replaces `DispatchQueue.main.async`.

## When to Use @MainActor

| Component | Annotation | Reason |
|-----------|------------|--------|
| ViewModel | `@MainActor class` | Updates @Published properties |
| SwiftUI View callbacks | Automatic | Views are implicitly MainActor |
| AVFoundation services | `@MainActor class` | AVAudioSession requires main thread |
| UI update methods | `@MainActor func` | Modifies view state |

## ViewModel Pattern

```swift
@MainActor
final class QuizViewModel: ObservableObject {
    @Published var state: QuizState = .idle
    @Published var errorMessage: String?

    private let networkService: NetworkServiceProtocol  // Actor (not MainActor)

    func loadData() async {
        state = .loading

        do {
            // Cross-actor call - awaits on network actor
            let data = await networkService.fetchData()

            // Back on MainActor - safe to update UI
            self.items = data
            state = .loaded
        } catch {
            errorMessage = error.localizedDescription
            state = .error
        }
    }
}
```

## Protocol with MainActor

```swift
@MainActor
protocol AudioServiceProtocol: Sendable {
    var isPlaying: Bool { get }
    func play(_ data: Data) async throws
}

@MainActor
final class AudioService: AudioServiceProtocol {
    var isPlaying: Bool = false

    func play(_ data: Data) async throws {
        isPlaying = true
        defer { isPlaying = false }
        // AVFoundation calls...
    }
}
```

## Bridging from Non-Isolated Code

When receiving callbacks from system APIs (NotificationCenter, delegates):

```swift
@MainActor
final class AudioService: NSObject {
    private var isPlaying = false

    // NotificationCenter callback is nonisolated
    nonisolated private func handleRouteChange(_ notification: Notification) {
        // Must hop to MainActor to access state
        Task { @MainActor in
            self.handleRouteChangeOnMain(notification)
        }
    }

    private func handleRouteChangeOnMain(_ notification: Notification) {
        // Safe to access isPlaying here
    }
}
```

## MainActor.run for One-Off Updates

```swift
actor NetworkService {
    func fetchAndUpdateUI() async throws -> Data {
        let data = try await session.data(from: url).0

        // Update UI from within actor
        await MainActor.run {
            NotificationCenter.default.post(name: .dataLoaded, object: data)
        }

        return data
    }
}
```

## Decoding on MainActor (Performance Consideration)

JSON decoding is CPU-bound. For small payloads, doing it on MainActor is fine:

```swift
@MainActor
func decodeResponse<T: Decodable>(_ data: Data) throws -> T {
    try JSONDecoder().decode(T.self, from: data)
}
```

For large payloads, decode off-main then transfer:

```swift
actor NetworkService {
    func fetchLargeData() async throws -> [Item] {
        let data = try await session.data(from: url).0
        let items = try JSONDecoder().decode([Item].self, from: data)  // Off main
        return items  // Transferred to caller's context
    }
}
```

## Common Mistakes

### Wrong: Blocking MainActor
```swift
@MainActor
func badExample() async {
    // This blocks UI for 5 seconds!
    try? await Task.sleep(nanoseconds: 5_000_000_000)
}
```

### Right: Background Work Then Update
```swift
@MainActor
func goodExample() async {
    let result = await backgroundService.processData()  // Work on background actor
    self.data = result  // Quick update on main
}
```

### Wrong: Missing MainActor on ViewModel
```swift
// Compiler error in Swift 6: @Published requires MainActor
class BrokenViewModel: ObservableObject {
    @Published var items: [Item] = []
}
```

### Right: Properly Annotated
```swift
@MainActor
final class CorrectViewModel: ObservableObject {
    @Published var items: [Item] = []
}
```
