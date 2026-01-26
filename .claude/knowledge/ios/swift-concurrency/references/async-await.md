# Async/Await Patterns

## Core Concept
Swift's async/await replaces completion handlers with linear, readable code. Errors propagate naturally with `try`.

## Basic Pattern

```swift
// Old: Completion handler (callback hell)
func fetchData(completion: @escaping (Result<Data, Error>) -> Void) {
    session.dataTask(with: url) { data, response, error in
        if let error = error {
            completion(.failure(error))
            return
        }
        completion(.success(data!))
    }.resume()
}

// New: Async/await (clean and linear)
func fetchData() async throws -> Data {
    let (data, _) = try await session.data(for: URLRequest(url: url))
    return data
}
```

## URLSession with Async/Await

```swift
actor NetworkService {
    private let session: URLSession

    func fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

## Parallel Execution with async let

```swift
// Sequential (slow) - 2 seconds total
let user = try await fetchUser()
let posts = try await fetchPosts()

// Parallel (fast) - 1 second total
async let user = fetchUser()
async let posts = fetchPosts()
let (fetchedUser, fetchedPosts) = try await (user, posts)
```

## Converting Completion Handlers

Use `withCheckedThrowingContinuation` to bridge callback-based APIs:

```swift
func requestPermission() async -> Bool {
    await withCheckedContinuation { continuation in
        AVAudioApplication.requestRecordPermission { granted in
            continuation.resume(returning: granted)
        }
    }
}
```

**Warning:** Ensure continuation resumes exactly once. Resuming twice crashes.

## Error Handling

```swift
func loadQuiz() async {
    do {
        let session = try await networkService.createSession()
        let response = try await networkService.startQuiz(sessionId: session.id)
        // Success path
    } catch let error as NetworkError {
        // Handle specific errors
        handleNetworkError(error)
    } catch {
        // Handle unknown errors
        errorMessage = error.localizedDescription
    }
}
```

## Timeouts

```swift
func fetchWithTimeout() async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await self.fetchData()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            throw TimeoutError()
        }

        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
```

## Best Practices

1. **Prefer async/await** over completion handlers for new code
2. **Use `async let`** for parallel independent operations
3. **Don't block** - use `await` instead of semaphores
4. **Handle errors** with do-catch, not Result types
5. **Mark throwing functions** with `throws` not optional returns
