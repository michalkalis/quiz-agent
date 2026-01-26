# Multipart Form Data Upload

## Basic Structure

```swift
actor NetworkService {
    func uploadFile(
        data: Data,
        fileName: String,
        mimeType: String,
        to endpoint: String
    ) async throws -> Response {
        let boundary = UUID().uuidString
        let url = baseURL.appendingPathComponent(endpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Build multipart body
        var body = Data()

        // Add file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (responseData, response) = try await session.data(for: request)
        // ... handle response
    }
}
```

## Audio File Upload

```swift
actor NetworkService {
    func submitVoiceAnswer(
        sessionId: String,
        audioData: Data,
        fileName: String = "answer.m4a"
    ) async throws -> QuizResponse {
        let endpoint = "/voice/submit/\(sessionId)"
        let boundary = UUID().uuidString
        let url = baseURL.appendingPathComponent(endpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        // Longer timeout for voice processing (transcription + evaluation + TTS)
        request.timeoutInterval = 120

        // Build multipart body
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try JSONDecoder().decode(QuizResponse.self, from: data)
    }
}
```

## Multiple Fields

```swift
func uploadWithMetadata(
    imageData: Data,
    imageName: String,
    title: String,
    description: String
) async throws -> UploadResponse {
    let boundary = UUID().uuidString

    var body = Data()

    // Text field: title
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"title\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(title)\r\n".data(using: .utf8)!)

    // Text field: description
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"description\"\r\n\r\n".data(using: .utf8)!)
    body.append("\(description)\r\n".data(using: .utf8)!)

    // File field: image
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Disposition: form-data; name=\"image\"; filename=\"\(imageName)\"\r\n".data(using: .utf8)!)
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
    body.append(imageData)
    body.append("\r\n".data(using: .utf8)!)

    // Close boundary
    body.append("--\(boundary)--\r\n".data(using: .utf8)!)

    // ... create request with body
}
```

## Helper Extension

```swift
extension Data {
    mutating func appendMultipartField(
        boundary: String,
        name: String,
        value: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(
        boundary: String,
        name: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func closeMultipartBoundary(_ boundary: String) {
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}

// Usage
var body = Data()
body.appendMultipartField(boundary: boundary, name: "title", value: "My Upload")
body.appendMultipartFile(boundary: boundary, name: "file", fileName: "image.jpg", mimeType: "image/jpeg", data: imageData)
body.closeMultipartBoundary(boundary)
```

## Common MIME Types

| File Type | MIME Type |
|-----------|-----------|
| M4A Audio | `audio/m4a` |
| MP3 Audio | `audio/mpeg` |
| WAV Audio | `audio/wav` |
| JPEG Image | `image/jpeg` |
| PNG Image | `image/png` |
| JSON | `application/json` |
| PDF | `application/pdf` |
