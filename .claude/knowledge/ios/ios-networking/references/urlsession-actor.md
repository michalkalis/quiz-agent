# Actor-Based URLSession Service

## Core Structure

```swift
protocol NetworkServiceProtocol: Sendable {
    func fetchData() async throws -> Data
    func postData(_ data: Data) async throws -> Response
}

actor NetworkService: NetworkServiceProtocol {
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: String = "https://api.example.com") {
        self.baseURL = URL(string: baseURL)!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
}
```

## Why Actor?

1. **Thread Safety**: Actor serializes access to mutable state (task registry, cache)
2. **No Locks Needed**: Swift compiler enforces isolation
3. **Async/Await Native**: Natural fit with URLSession async methods

## Basic Requests

### GET Request
```swift
actor NetworkService {
    func fetchItems() async throws -> [Item] {
        let url = baseURL.appendingPathComponent("/items")

        let (data, response) = try await session.data(from: url)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try JSONDecoder().decode([Item].self, from: data)
    }
}
```

### POST with JSON
```swift
actor NetworkService {
    func createSession(maxQuestions: Int) async throws -> Session {
        let url = baseURL.appendingPathComponent("/sessions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["max_questions": maxQuestions]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try JSONDecoder().decode(Session.self, from: data)
    }
}
```

### DELETE Request
```swift
actor NetworkService {
    func deleteSession(id: String) async throws {
        let url = baseURL.appendingPathComponent("/sessions/\(id)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkError.invalidResponse
        }
    }
}
```

## URL Building with Query Parameters

```swift
actor NetworkService {
    func startQuiz(sessionId: String, audio: Bool) async throws -> QuizResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/sessions/\(sessionId)/start"),
            resolvingAgainstBaseURL: false
        )!

        components.queryItems = [
            URLQueryItem(name: "audio", value: audio ? "true" : "false")
        ]

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        // ... handle response
    }
}
```

## Task Registry for Cancellation

```swift
actor NetworkService {
    private var activeTasks: [UUID: URLSessionDataTask] = [:]

    private func registerTask(_ id: UUID, task: URLSessionDataTask) {
        activeTasks[id] = task
    }

    private func unregisterTask(_ id: UUID) {
        activeTasks.removeValue(forKey: id)
    }

    func cancelTask(_ id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
    }

    func downloadWithCancellation(from url: URL) async throws -> Data {
        let taskId = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: url) { [weak self] data, response, error in
                    Task { await self?.unregisterTask(taskId) }

                    if let error = error as? URLError, error.code == .cancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if let error = error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let data = data else {
                        continuation.resume(throwing: NetworkError.invalidResponse)
                        return
                    }

                    continuation.resume(returning: data)
                }

                registerTask(taskId, task: task)
                task.resume()
            }
        } onCancel: {
            Task { await self.cancelTask(taskId) }
        }
    }
}
```

## Configuration Options

```swift
actor NetworkService {
    init() {
        let config = URLSessionConfiguration.default

        // Timeouts
        config.timeoutIntervalForRequest = 30  // Per-request
        config.timeoutIntervalForResource = 60  // Total resource time

        // Caching
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Headers for all requests
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "MyApp/1.0"
        ]

        self.session = URLSession(configuration: config)
    }
}
```
