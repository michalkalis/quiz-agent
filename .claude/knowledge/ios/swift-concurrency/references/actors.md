# Actor Isolation

## Core Concept
Actors protect mutable state by ensuring only one task accesses their internal state at a time. They replace manual locking (DispatchQueue, locks) with compiler-enforced safety.

## When to Use Actors

| Use Case | Type | Reason |
|----------|------|--------|
| Network service | `actor` | State (tasks, cache) accessed from multiple callers |
| Database service | `actor` | Serialize database writes |
| Cache manager | `actor` | Thread-safe read/write |
| UI/ViewModel | `@MainActor` class | UI must be on main thread |
| Stateless utility | `struct` | No mutable state to protect |

## Basic Actor Pattern

```swift
actor NetworkService {
    private var activeTasks: [UUID: URLSessionDataTask] = [:]
    private let session: URLSession

    init() {
        self.session = URLSession(configuration: .default)
    }

    func fetchData(from url: URL) async throws -> Data {
        let taskId = UUID()

        // This is safe - only one task accesses activeTasks at a time
        let task = session.dataTask(with: url)
        activeTasks[taskId] = task

        defer { activeTasks.removeValue(forKey: taskId) }

        return try await session.data(from: url).0
    }

    func cancelTask(_ id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
    }
}
```

## Calling Actor Methods

All actor method calls require `await` from outside:

```swift
let service = NetworkService()

// From another context (e.g., ViewModel)
let data = await service.fetchData(from: url)  // await required

// From within the same actor
func internalMethod() {
    // No await needed - already isolated
    activeTasks[id] = task
}
```

## Actor vs @MainActor

```swift
// Regular actor - runs on any thread, serializes access
actor CacheService {
    private var cache: [String: Data] = [:]
}

// MainActor - always runs on main thread
@MainActor
final class ViewModel: ObservableObject {
    @Published var items: [Item] = []  // UI updates must be on main
}
```

## Nonisolated Methods

Methods that don't access mutable state can be `nonisolated`:

```swift
actor NetworkService {
    let baseURL: URL  // Immutable - safe to access

    nonisolated var apiVersion: String {
        "v1"  // Computed from immutable data
    }

    nonisolated func buildURL(path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
}
```

## Actor Reentrancy

**Warning:** Actors can be re-entered at any `await` point:

```swift
actor Counter {
    var value = 0

    func incrementTwice() async {
        value += 1
        await someAsyncWork()  // Another task could run here!
        value += 1  // value might not be what you expect
    }
}
```

**Solution:** Capture state before await or use serial execution patterns.

## Nested Actor (Serial Queue Pattern)

For operations that must complete atomically:

```swift
actor AudioService {
    private actor OperationQueue {
        private var currentOperation: UUID?

        func acquire(_ id: UUID) async -> Bool {
            while currentOperation != nil {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            currentOperation = id
            return true
        }

        func release(_ id: UUID) {
            if currentOperation == id {
                currentOperation = nil
            }
        }
    }

    private let queue = OperationQueue()

    func playAudio(_ data: Data) async throws {
        let id = UUID()
        guard await queue.acquire(id) else { return }
        defer { Task { await queue.release(id) } }

        // Only one playback at a time
        try await performPlayback(data)
    }
}
```

## Protocol Conformance

Actors conforming to protocols need careful handling:

```swift
protocol NetworkServiceProtocol: Sendable {
    func fetch() async throws -> Data
}

// Actor automatically conforms to Sendable
actor NetworkService: NetworkServiceProtocol {
    func fetch() async throws -> Data { ... }
}
```
