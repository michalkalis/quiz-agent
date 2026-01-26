# Task Management

## Core Concept
`Task` is Swift's unit of asynchronous work. Unlike GCD, Tasks support structured concurrency with automatic cancellation propagation.

## Creating Tasks

### Unstructured Task (Fire and Forget)
```swift
@MainActor
final class ViewModel: ObservableObject {
    func userTappedButton() {
        Task {
            await loadData()  // Runs asynchronously
        }
    }
}
```

### Storing Task Reference (For Cancellation)
```swift
@MainActor
final class ViewModel: ObservableObject {
    private var loadingTask: Task<Void, Never>?

    func startLoading() {
        loadingTask = Task {
            await loadData()
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
    }
}
```

## Task Cancellation

### Checking Cancellation
```swift
func processItems(_ items: [Item]) async throws {
    for item in items {
        // Check before each iteration
        try Task.checkCancellation()
        await process(item)
    }
}

// Or non-throwing version
func processItems(_ items: [Item]) async {
    for item in items {
        if Task.isCancelled { return }
        await process(item)
    }
}
```

### Cancellation Handler Pattern
```swift
func downloadWithCleanup(url: URL) async throws -> Data {
    let taskId = UUID()

    return try await withTaskCancellationHandler {
        // Main work
        try await networkService.download(url: url, taskId: taskId)
    } onCancel: {
        // Cleanup when cancelled (runs immediately)
        Task {
            await networkService.cancelDownload(taskId: taskId)
        }
    }
}
```

## Countdown Timer Pattern

```swift
@MainActor
final class ViewModel: ObservableObject {
    @Published var countdown: Int = 0
    private var countdownTask: Task<Void, Never>?

    func startCountdown(from seconds: Int) {
        countdownTask?.cancel()

        countdownTask = Task { [weak self] in
            for remaining in (0...seconds).reversed() {
                guard !Task.isCancelled else { return }

                self?.countdown = remaining

                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            // Countdown complete
            self?.onCountdownComplete()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
    }
}
```

## Task Priority

```swift
// High priority for user-initiated work
Task(priority: .userInitiated) {
    await loadVisibleContent()
}

// Low priority for background work
Task(priority: .background) {
    await syncCache()
}

// Inherit priority from context (default)
Task {
    await normalWork()
}
```

## TaskGroup for Parallel Work

```swift
func loadAllImages(urls: [URL]) async throws -> [UIImage] {
    try await withThrowingTaskGroup(of: UIImage.self) { group in
        for url in urls {
            group.addTask {
                try await self.loadImage(from: url)
            }
        }

        var images: [UIImage] = []
        for try await image in group {
            images.append(image)
        }
        return images
    }
}
```

## Detached Tasks

For work that shouldn't inherit actor context:

```swift
@MainActor
func startBackgroundSync() {
    // This inherits MainActor - BAD for CPU work
    Task {
        await heavyComputation()  // Blocks main!
    }

    // Detached - runs on background
    Task.detached(priority: .background) {
        await heavyComputation()  // Good!
    }
}
```

## Task Sleep (Delays)

```swift
// Sleep for 1 second
try await Task.sleep(nanoseconds: 1_000_000_000)

// Sleep for 0.5 seconds
try await Task.sleep(nanoseconds: 500_000_000)

// Sleep for 100 milliseconds
try await Task.sleep(nanoseconds: 100_000_000)

// iOS 16+ with Duration
try await Task.sleep(for: .seconds(1))
```

## Common Patterns

### Debouncing with Task
```swift
@MainActor
final class SearchViewModel: ObservableObject {
    private var searchTask: Task<Void, Never>?

    func search(query: String) {
        searchTask?.cancel()

        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce

            guard !Task.isCancelled else { return }
            await performSearch(query)
        }
    }
}
```

### Timeout with Task
```swift
func fetchWithTimeout() async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await self.actualFetch()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw TimeoutError()
        }

        guard let result = try await group.next() else {
            throw TimeoutError()
        }

        group.cancelAll()
        return result
    }
}
```

### Cleanup on Deallocation
```swift
@MainActor
final class ViewModel: ObservableObject {
    private var backgroundTask: Task<Void, Never>?

    deinit {
        backgroundTask?.cancel()
    }
}
```
