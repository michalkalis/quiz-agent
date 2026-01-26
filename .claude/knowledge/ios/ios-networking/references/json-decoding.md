# JSON Decoding and Troubleshooting

## Basic Decoding Setup

```swift
actor NetworkService {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Use manual CodingKeys instead of automatic snake_case
        return decoder
    }()

    func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let (data, _) = try await session.data(from: url)
        return try decoder.decode(T.self, from: data)
    }
}
```

## Model with CodingKeys

```swift
struct Question: Codable {
    let id: String
    let question: String
    let correctAnswer: String
    let category: String?
    let source: Source?

    enum CodingKeys: String, CodingKey {
        case id
        case question
        case correctAnswer = "correct_answer"  // snake_case from API
        case category
        case source
    }
}

struct Source: Codable {
    let title: String?
    let url: String?
    let articleTitle: String?

    enum CodingKeys: String, CodingKey {
        case title
        case url
        case articleTitle = "article_title"
    }
}
```

## Debugging Decoding Errors

```swift
func decodeWithLogging<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        // Log the raw response
        if let json = String(data: data, encoding: .utf8) {
            print("📄 Response JSON: \(json)")
        }

        // Log detailed error info
        if let decodingError = error as? DecodingError {
            logDecodingError(decodingError)
        }

        throw error
    }
}

private func logDecodingError(_ error: DecodingError) {
    switch error {
    case .keyNotFound(let key, let context):
        print("🔍 Missing key: '\(key.stringValue)'")
        print("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")

    case .typeMismatch(let type, let context):
        print("🔍 Type mismatch: expected \(type)")
        print("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
        print("   Debug: \(context.debugDescription)")

    case .valueNotFound(let type, let context):
        print("🔍 Null value for non-optional: \(type)")
        print("   Path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")

    case .dataCorrupted(let context):
        print("🔍 Data corrupted at: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
        print("   Debug: \(context.debugDescription)")

    @unknown default:
        print("🔍 Unknown decoding error")
    }
}
```

## Common Decoding Issues

### Issue: Missing Optional Field
```json
{"name": "John"}  // "email" field missing
```

```swift
// ❌ Will fail if email is missing
struct User: Codable {
    let name: String
    let email: String  // Non-optional
}

// ✅ Handles missing field
struct User: Codable {
    let name: String
    let email: String?  // Optional
}
```

### Issue: Type Mismatch
```json
{"count": "5"}  // String instead of Int
```

```swift
// ❌ Fails - expects Int
struct Stats: Codable {
    let count: Int
}

// ✅ Custom decoding for flexible types
struct Stats: Codable {
    let count: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try Int first, then String
        if let intValue = try? container.decode(Int.self, forKey: .count) {
            count = intValue
        } else if let stringValue = try? container.decode(String.self, forKey: .count),
                  let intValue = Int(stringValue) {
            count = intValue
        } else {
            throw DecodingError.typeMismatch(Int.self, .init(
                codingPath: [CodingKeys.count],
                debugDescription: "Expected Int or String"
            ))
        }
    }
}
```

### Issue: Nested Null Object
```json
{"user": null}  // Null object, not missing
```

```swift
struct Response: Codable {
    let user: User?  // Must be optional to handle null
}
```

### Issue: Array with Mixed Types
```json
{"items": [1, "two", 3]}
```

```swift
// Custom decoding to skip invalid items
struct Response: Codable {
    let items: [Int]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var itemsContainer = try container.nestedUnkeyedContainer(forKey: .items)

        var items: [Int] = []
        while !itemsContainer.isAtEnd {
            if let item = try? itemsContainer.decode(Int.self) {
                items.append(item)
            } else {
                _ = try? itemsContainer.decode(String.self)  // Skip non-Int
            }
        }
        self.items = items
    }
}
```

## Date Decoding Strategies

```swift
let decoder = JSONDecoder()

// ISO 8601 (default for most APIs)
decoder.dateDecodingStrategy = .iso8601
// "2024-01-15T10:30:00Z"

// Unix timestamp (seconds)
decoder.dateDecodingStrategy = .secondsSince1970
// 1705314600

// Unix timestamp (milliseconds)
decoder.dateDecodingStrategy = .millisecondsSince1970
// 1705314600000

// Custom format
let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd"
decoder.dateDecodingStrategy = .formatted(formatter)
// "2024-01-15"
```

## Validating API Contract

```swift
#if DEBUG
/// Development-only validation against expected schema
func validateResponse<T: Decodable>(_ data: Data, expecting type: T.Type) {
    do {
        _ = try JSONDecoder().decode(T.self, from: data)
        print("✅ Response matches \(T.self) schema")
    } catch {
        print("❌ Schema mismatch for \(T.self)")
        if let json = String(data: data, encoding: .utf8) {
            print("📄 Actual: \(json)")
        }
    }
}
#endif
```
