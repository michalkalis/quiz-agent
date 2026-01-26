# iOS Networking Patterns

Use this knowledge when working with URLSession, API requests, error handling, or multipart uploads.

## Quick Reference

| Need | Reference |
|------|-----------|
| Actor-based network service | [urlsession-actor.md](references/urlsession-actor.md) |
| Error handling patterns | [error-handling.md](references/error-handling.md) |
| File uploads (multipart) | [multipart-upload.md](references/multipart-upload.md) |
| Timeouts and retry | [timeout-retry.md](references/timeout-retry.md) |
| JSON decoding issues | [json-decoding.md](references/json-decoding.md) |

## Decision Tree

### 1. Creating a network service?
Use `actor` for thread-safe state:
```swift
actor NetworkService {
    private let session: URLSession
    private var activeTasks: [UUID: Task<Data, Error>] = [:]
}
```

### 2. Need different timeouts for different operations?
Create multiple URLSession configurations:
```swift
let normalConfig = URLSessionConfiguration.default
normalConfig.timeoutIntervalForRequest = 30

let uploadConfig = URLSessionConfiguration.default
uploadConfig.timeoutIntervalForRequest = 120  // AI processing
```

### 3. Uploading files?
Use multipart/form-data:
```swift
var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
```

### 4. Decoding failing?
Check snake_case vs camelCase:
```swift
enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
}
```

## Common Patterns

### Protocol-Based Service
```swift
protocol NetworkServiceProtocol: Sendable {
    func fetch<T: Decodable>(_ type: T.Type, from endpoint: String) async throws -> T
}

actor NetworkService: NetworkServiceProtocol { ... }
```

### Error Enum
```swift
enum NetworkError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
}
```
