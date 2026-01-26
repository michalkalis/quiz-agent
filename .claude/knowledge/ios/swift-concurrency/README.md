# Swift 6 Concurrency Patterns

Use this knowledge when working with async code, actors, thread safety, or Swift 6 strict concurrency.

## Quick Reference

| Need | Solution | Reference |
|------|----------|-----------|
| Update UI from async code | `@MainActor` | [main-actor.md](references/main-actor.md) |
| Protect mutable state | `actor` keyword | [actors.md](references/actors.md) |
| Network/I/O operations | `async/await` | [async-await.md](references/async-await.md) |
| Pass data between actors | `Sendable` conformance | [sendable.md](references/sendable.md) |
| Background work with cleanup | `Task` with cancellation | [task-management.md](references/task-management.md) |

## Decision Tree

### 1. Is this code updating UI (SwiftUI @Published, view state)?
**YES** → Use `@MainActor` annotation on the class/method
```swift
@MainActor
final class QuizViewModel: ObservableObject {
    @Published var state: QuizState = .idle  // Safe - always on main thread
}
```

### 2. Does this code have mutable internal state accessed from multiple places?
**YES** → Use `actor` (not class)
```swift
actor NetworkService {
    private var activeTasks: [UUID: URLSessionDataTask] = [:]  // Thread-safe
}
```

### 3. Is this an I/O operation (network, file, audio)?
**YES** → Use `async/await` instead of completion handlers
```swift
let data = try await session.data(for: request)
```

### 4. Need to pass data between actors?
**YES** → Ensure `Sendable` conformance
```swift
struct QuizSettings: Sendable {
    let difficulty: String
}
```

## Swift 6 Strict Concurrency Checklist

- [ ] All `@Published` properties on `@MainActor` classes
- [ ] Network services as `actor` (not `@MainActor`)
- [ ] UI services (audio, video) as `@MainActor`
- [ ] Protocols marked `Sendable` if crossing isolation
- [ ] `nonisolated(unsafe)` only for NotificationCenter observers
