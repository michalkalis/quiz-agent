# Sendable Conformance

## Core Concept
`Sendable` is a marker protocol indicating a type can be safely passed across actor/concurrency boundaries. Swift 6 strict concurrency requires Sendable for cross-isolation data.

## Automatic Sendable Conformance

These types are implicitly Sendable:
- Value types (struct, enum) with all Sendable properties
- Actors (always Sendable)
- Final classes with immutable stored properties
- Primitive types (Int, String, Bool, etc.)

```swift
// Automatically Sendable
struct QuizSettings {
    let difficulty: String
    let maxQuestions: Int
}

// Automatically Sendable
enum QuizState {
    case idle
    case playing
    case finished
}
```

## Explicit Sendable Conformance

Mark types explicitly when needed:

```swift
// Explicit conformance for clarity
struct NetworkConfig: Sendable {
    let baseURL: URL
    let timeout: TimeInterval
}

// Protocol requiring Sendable
protocol NetworkServiceProtocol: Sendable {
    func fetch() async throws -> Data
}
```

## When Sendable is Required

```swift
@MainActor
final class ViewModel: ObservableObject {
    func updateFromNetwork() async {
        // QuizSettings crosses from actor to MainActor
        // Must be Sendable
        let settings: QuizSettings = await networkService.getSettings()
        self.settings = settings
    }
}
```

## Non-Sendable Types

Classes with mutable state are NOT Sendable by default:

```swift
// NOT Sendable - mutable state
class MutableCache {
    var items: [String: Data] = [:]  // Mutable!
}

// Solution 1: Make it an actor
actor SafeCache {
    var items: [String: Data] = [:]
}

// Solution 2: Make it immutable
final class ImmutableConfig: Sendable {
    let baseURL: URL  // Immutable
    let timeout: TimeInterval  // Immutable

    init(baseURL: URL, timeout: TimeInterval) {
        self.baseURL = baseURL
        self.timeout = timeout
    }
}
```

## @unchecked Sendable

For types that are thread-safe but compiler can't verify:

```swift
// URLSession is thread-safe but not marked Sendable
final class NetworkService: @unchecked Sendable {
    private let session: URLSession  // Thread-safe internally

    init() {
        self.session = URLSession(configuration: .default)
    }
}
```

**Warning:** Use `@unchecked Sendable` sparingly. You're asserting thread-safety the compiler can't verify.

## nonisolated(unsafe)

For stored properties that can't be Sendable but are accessed safely:

```swift
@MainActor
final class AudioService {
    // NotificationCenter observers aren't Sendable
    // But we only access on main queue
    nonisolated(unsafe) private var routeObserver: NSObjectProtocol?

    deinit {
        if let observer = routeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
```

## Closures and Sendable

Closures crossing isolation boundaries need `@Sendable`:

```swift
actor DataProcessor {
    func process(completion: @Sendable @escaping () -> Void) {
        Task {
            // Work...
            completion()
        }
    }
}
```

## Common Patterns

### Sendable Error Types
```swift
enum NetworkError: Error, Sendable {
    case invalidResponse
    case timeout
    case decodingFailed(String)  // String is Sendable
}
```

### Sendable Protocols
```swift
protocol QuizServiceProtocol: Sendable {
    func startQuiz() async throws -> QuizSession
}

// Actors automatically satisfy Sendable
actor QuizService: QuizServiceProtocol {
    func startQuiz() async throws -> QuizSession { ... }
}
```

### Transferring Non-Sendable Data
```swift
// If you must work with non-Sendable types
actor ImageProcessor {
    func processImage(_ image: UIImage) async -> Data {
        // UIImage isn't Sendable, but we can return Sendable Data
        return image.pngData() ?? Data()
    }
}
```

## Debugging Sendable Issues

Compiler errors like:
```
Capture of 'self' with non-sendable type 'ViewController' in a `@Sendable` closure
```

Solutions:
1. Make the type Sendable (if possible)
2. Use `@unchecked Sendable` (if you're sure it's safe)
3. Use `nonisolated(unsafe)` for stored properties
4. Restructure to avoid crossing isolation boundaries
