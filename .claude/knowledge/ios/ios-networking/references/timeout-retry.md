# Timeout and Retry Strategies

## URLSession Timeout Configuration

```swift
actor NetworkService {
    init() {
        let config = URLSessionConfiguration.default

        // Time to wait for initial response
        config.timeoutIntervalForRequest = 30  // 30 seconds

        // Total time for entire resource download
        config.timeoutIntervalForResource = 60  // 60 seconds

        self.session = URLSession(configuration: config)
    }
}
```

## Per-Request Timeout Override

```swift
func submitVoiceAnswer(audioData: Data) async throws -> Response {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    // Override default timeout for slow operations
    // Voice processing: upload + transcription + AI evaluation + TTS
    request.timeoutInterval = 120  // 2 minutes

    let (data, response) = try await session.data(for: request)
    // ...
}
```

## Recommended Timeouts by Operation

| Operation | Timeout | Reason |
|-----------|---------|--------|
| Simple GET | 30s | Standard API call |
| JSON POST | 30s | Small payload |
| File upload | 60-120s | Large payload + processing |
| Voice submission | 120s | Upload + Whisper + GPT-4 + TTS |
| File download | 60s | Depends on file size |

## Exponential Backoff Retry

```swift
actor NetworkService {
    func fetchWithRetry<T: Decodable>(
        from url: URL,
        maxRetries: Int = 3
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await session.data(from: url)

                guard let http = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }

                // Don't retry client errors (4xx)
                if (400...499).contains(http.statusCode) {
                    throw NetworkError.serverError(statusCode: http.statusCode, message: "Client error")
                }

                // Retry server errors (5xx)
                if (500...599).contains(http.statusCode) {
                    throw NetworkError.serverError(statusCode: http.statusCode, message: "Server error")
                }

                return try JSONDecoder().decode(T.self, from: data)

            } catch let error as NetworkError {
                // Don't retry client errors
                if case .serverError(let code, _) = error, (400...499).contains(code) {
                    throw error
                }
                lastError = error

            } catch {
                lastError = error
            }

            // Exponential backoff: 1s, 2s, 4s
            if attempt < maxRetries - 1 {
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }

        throw lastError ?? NetworkError.invalidResponse
    }
}
```

## Retry Only Transient Errors

```swift
private func shouldRetry(error: Error) -> Bool {
    // Retry network errors
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost:
            return true
        default:
            return false
        }
    }

    // Retry 5xx server errors
    if let networkError = error as? NetworkError,
       case .serverError(let code, _) = networkError {
        return (500...599).contains(code)
    }

    return false
}
```

## Timeout with Task Racing

```swift
func fetchWithTimeout<T>(
    _ operation: @escaping () async throws -> T,
    timeout: TimeInterval = 30
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // Main operation
        group.addTask {
            try await operation()
        }

        // Timeout task
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw NetworkError.timeout
        }

        // Return first to complete
        guard let result = try await group.next() else {
            throw NetworkError.timeout
        }

        group.cancelAll()
        return result
    }
}

// Usage
let data = try await fetchWithTimeout({
    try await networkService.fetchData()
}, timeout: 15)
```

## Download with Integrity Check

```swift
func downloadAudio(from urlString: String) async throws -> Data {
    let (data, response) = try await session.data(from: url)

    guard let http = response as? HTTPURLResponse else {
        throw NetworkError.invalidResponse
    }

    // Verify download completeness
    if let expectedLength = http.value(forHTTPHeaderField: "Content-Length"),
       let expectedBytes = Int64(expectedLength),
       expectedBytes > 0 {
        let actualBytes = Int64(data.count)

        if actualBytes != expectedBytes {
            // Incomplete download - worth retrying
            throw NetworkError.invalidResponse
        }
    }

    return data
}
```

## Cancellation-Aware Operations

```swift
func fetchWithCancellation() async throws -> Data {
    return try await withTaskCancellationHandler {
        // Check before expensive operation
        try Task.checkCancellation()

        let data = try await session.data(from: url).0

        // Check after operation
        try Task.checkCancellation()

        return data
    } onCancel: {
        // Cleanup if cancelled
    }
}
```
