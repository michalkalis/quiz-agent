# JSON Decoding Error Troubleshooting

## Step 1: Log Raw Response

```swift
func debugDecode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        // Log raw JSON
        if let json = String(data: data, encoding: .utf8) {
            print("📄 Response JSON:\n\(json)")
        }

        // Log detailed error
        logDecodingError(error)

        throw error
    }
}
```

## Step 2: Identify Error Type

```swift
func logDecodingError(_ error: Error) {
    guard let decodingError = error as? DecodingError else {
        print("❌ Non-decoding error: \(error)")
        return
    }

    switch decodingError {
    case .keyNotFound(let key, let context):
        print("🔍 Missing key: '\(key.stringValue)'")
        print("   Path: \(formatPath(context.codingPath))")

    case .typeMismatch(let type, let context):
        print("🔍 Type mismatch: expected \(type)")
        print("   Path: \(formatPath(context.codingPath))")
        print("   Debug: \(context.debugDescription)")

    case .valueNotFound(let type, let context):
        print("🔍 Null value for non-optional: \(type)")
        print("   Path: \(formatPath(context.codingPath))")

    case .dataCorrupted(let context):
        print("🔍 Data corrupted")
        print("   Path: \(formatPath(context.codingPath))")
        print("   Debug: \(context.debugDescription)")

    @unknown default:
        print("🔍 Unknown error: \(error)")
    }
}

func formatPath(_ path: [CodingKey]) -> String {
    path.map { $0.stringValue }.joined(separator: " → ")
}
```

## Common Errors and Fixes

### keyNotFound
```
Missing key: 'correct_answer' at path: question
```

**Cause:** API returns `correct_answer` but model expects `correctAnswer`

**Fix:** Add CodingKeys:
```swift
struct Question: Codable {
    let correctAnswer: String

    enum CodingKeys: String, CodingKey {
        case correctAnswer = "correct_answer"
    }
}
```

### typeMismatch
```
Type mismatch: expected Int at path: count
```

**Cause:** API returns `"5"` (string) but model expects `Int`

**JSON:**
```json
{"count": "5"}
```

**Fix:** Change type or add custom decoding:
```swift
// Option 1: Accept string
let count: String

// Option 2: Custom decoding
init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let intValue = try? container.decode(Int.self, forKey: .count) {
        count = intValue
    } else if let stringValue = try? container.decode(String.self, forKey: .count),
              let intValue = Int(stringValue) {
        count = intValue
    } else {
        throw DecodingError.typeMismatch(...)
    }
}
```

### valueNotFound
```
Null value for non-optional: String at path: email
```

**Cause:** API returns `null` but model expects non-optional

**JSON:**
```json
{"name": "John", "email": null}
```

**Fix:** Make property optional:
```swift
struct User: Codable {
    let name: String
    let email: String?  // Was: let email: String
}
```

### dataCorrupted
```
Data corrupted at path: timestamp
Debug: Date string does not match format
```

**Cause:** Date format mismatch

**Fix:** Configure date strategy:
```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601  // or .secondsSince1970, .formatted(...)
```

## Verify Model Against API

### 1. Get API Response
```bash
curl http://localhost:8002/api/v1/sessions/abc123 | python -m json.tool
```

### 2. Compare with Model
```swift
// API returns:
// {
//   "session_id": "abc",
//   "is_finished": false,
//   "current_question": { ... }
// }

struct Session: Codable {
    let sessionId: String        // ✅ Matches
    let isFinished: Bool         // ✅ Matches
    let currentQuestion: Question?  // ✅ Matches

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"      // ✅ Snake case mapped
        case isFinished = "is_finished"    // ✅ Snake case mapped
        case currentQuestion = "current_question"
    }
}
```

## Quick Validation Script

Add to tests for API contract validation:

```swift
#if DEBUG
func validateAPIContract() async {
    do {
        let data = try await networkService.fetchRawData()

        // Try decoding each model
        _ = try JSONDecoder().decode(Session.self, from: data)
        print("✅ Session model matches API")

    } catch {
        print("❌ API contract mismatch")
        logDecodingError(error)
    }
}
#endif
```

## Date Format Reference

| Strategy | Format | Example |
|----------|--------|---------|
| `.iso8601` | ISO 8601 | `2024-01-15T10:30:00Z` |
| `.secondsSince1970` | Unix timestamp | `1705314600` |
| `.millisecondsSince1970` | Unix ms | `1705314600000` |
| `.formatted(formatter)` | Custom | Depends on formatter |
