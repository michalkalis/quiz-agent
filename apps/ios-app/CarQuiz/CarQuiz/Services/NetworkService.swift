//
//  NetworkService.swift
//  CarQuiz
//
//  REST API client for Quiz Agent backend
//  Actor-based for thread-safe networking
//

@preconcurrency import Foundation

/// Protocol for network operations
protocol NetworkServiceProtocol: Sendable {
    func createSession(maxQuestions: Int, difficulty: String, language: String, category: String?) async throws -> QuizSession
    func startQuiz(sessionId: String, excludedQuestionIds: [String]) async throws -> QuizResponse
    func submitVoiceAnswer(sessionId: String, audioData: Data, fileName: String) async throws -> QuizResponse
    func submitTextInput(sessionId: String, input: String, audio: Bool) async throws -> QuizResponse
    func downloadAudio(from urlString: String) async throws -> Data
    func endSession(sessionId: String) async throws
}

/// Thread-safe network service using Swift 6 actor
actor NetworkService: NetworkServiceProtocol {
    private let baseURL: URL
    private let session: URLSession

    // Task registry for cancellation support
    private var activeTasks: [UUID: URLSessionDataTask] = [:]

    init(baseURL: String = Config.apiBaseURL) {
        self.baseURL = URL(string: baseURL)!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Task Registry

    private func registerTask(_ id: UUID, task: URLSessionDataTask) {
        activeTasks[id] = task
    }

    private func unregisterTask(_ id: UUID) {
        activeTasks.removeValue(forKey: id)
    }

    private func cancelTask(_ id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)

        if Config.verboseLogging {
            print("🌐 Cancelled task: \(id)")
        }
    }

    // MARK: - Session Management

    func createSession(maxQuestions: Int = 10, difficulty: String = "medium", language: String = "en", category: String? = nil) async throws -> QuizSession {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions")

        if Config.verboseLogging {
            print("🌐 Base URL: \(baseURL)")
            print("🌐 Full endpoint: \(endpoint)")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "max_questions": maxQuestions,
            "difficulty": difficulty,
            "mode": "single",
            "language": language
        ]

        // Add category if specified
        if let category = category {
            body["category"] = category
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if Config.verboseLogging {
            print("🌐 POST \(endpoint)")
        }

        let (data, response) = try await session.data(for: request)

        if Config.verboseLogging {
            print("📥 Response received: \(data.count) bytes")
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 Status code: \(httpResponse.statusCode)")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(QuizSession.self, from: data)
        }
    }

    func startQuiz(sessionId: String, excludedQuestionIds: [String] = []) async throws -> QuizResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "audio", value: "true")]

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Send excluded question IDs in request body
        let body: [String: Any] = [
            "excluded_question_ids": excludedQuestionIds
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if Config.verboseLogging {
            print("🌐 POST \(url) with \(excludedQuestionIds.count) excluded IDs")
        }

        let (data, response) = try await session.data(for: request)

        if Config.verboseLogging {
            print("📥 Response received: \(data.count) bytes")
            if let httpResponse = response as? HTTPURLResponse {
                print("📊 Status code: \(httpResponse.statusCode)")
            }
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if Config.verboseLogging {
                if let httpResponse = response as? HTTPURLResponse {
                    print("❌ HTTP error: \(httpResponse.statusCode)")
                }
                if let responseString = String(data: data, encoding: .utf8) {
                    print("📄 Response body: \(responseString)")
                }
            }
            throw NetworkError.invalidResponse
        }

        return try await decodeQuizResponse(from: data)
    }

    func endSession(sessionId: String) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"

        if Config.verboseLogging {
            print("🌐 DELETE \(endpoint)")
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }
    }

    // MARK: - Voice Submission

    func submitVoiceAnswer(sessionId: String, audioData: Data, fileName: String = "answer.m4a") async throws -> QuizResponse {
        let endpoint = baseURL.appendingPathComponent("/api/v1/voice/submit/\(sessionId)")

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Voice submission requires longer timeout due to:
        // 1. Audio upload, 2. Whisper transcription, 3. GPT-4 evaluation, 4. TTS generation
        request.timeoutInterval = 120  // 2 minutes for AI processing

        // Build multipart form data
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        if Config.verboseLogging {
            print("🌐 POST \(endpoint) (audio: \(audioData.count) bytes)")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try await decodeQuizResponse(from: data)
    }

    func submitTextInput(sessionId: String, input: String, audio: Bool = true) async throws -> QuizResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/input"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "audio", value: audio ? "true" : "false")]

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Text submission with GPT-4 evaluation and TTS
        request.timeoutInterval = 60

        // Build JSON body
        let body = ["input": input]
        request.httpBody = try JSONEncoder().encode(body)

        if Config.verboseLogging {
            print("🌐 POST \(url) (text: \(input.prefix(50))...)")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try await decodeQuizResponse(from: data)
    }

    // MARK: - Audio Download

    func downloadAudio(from urlString: String) async throws -> Data {
        let taskId = UUID()

        // Handle relative vs absolute URLs
        let url: URL
        if urlString.hasPrefix("http") {
            guard let absoluteURL = URL(string: urlString) else {
                throw NetworkError.invalidURL
            }
            url = absoluteURL
        } else {
            url = baseURL.appendingPathComponent(urlString)
        }

        if Config.verboseLogging {
            print("🌐 GET \(url)")
        }

        // IMPORTANT: Disable caching for audio downloads
        // Backend returns same URL for different questions, so we must bypass cache
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Use withTaskCancellationHandler for proper cleanup
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let task = session.dataTask(with: request) { [weak self] data, response, error in
                    Task {
                        await self?.unregisterTask(taskId)

                        // Handle cancellation gracefully
                        if let error = error as? URLError, error.code == .cancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }

                        guard let httpResponse = response as? HTTPURLResponse,
                              (200...299).contains(httpResponse.statusCode),
                              let data = data else {
                            continuation.resume(throwing: NetworkError.invalidResponse)
                            return
                        }

                        // Verify download integrity by checking Content-Length
                        if let expectedLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                           let expectedBytes = Int64(expectedLength),
                           expectedBytes > 0 {
                            let actualBytes = Int64(data.count)

                            if actualBytes != expectedBytes {
                                if Config.verboseLogging {
                                    print("⚠️ Download size mismatch: expected \(expectedBytes) bytes, got \(actualBytes) bytes")
                                }
                                continuation.resume(throwing: NetworkError.invalidResponse)
                                return
                            }

                            if Config.verboseLogging {
                                print("✓ Download integrity verified: \(actualBytes) bytes")
                            }
                        }

                        continuation.resume(returning: data)
                    }
                }

                registerTask(taskId, task: task)
                task.resume()
            }
        } onCancel: {
            Task {
                await self.cancelTask(taskId)
            }
        }
    }

    // MARK: - Helper Methods

    private func decodeQuizResponse(from data: Data) async throws -> QuizResponse {
        return try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // Note: Using manual CodingKeys in models, not automatic snake_case conversion

            do {
                return try decoder.decode(QuizResponse.self, from: data)
            } catch {
                if Config.verboseLogging {
                    print("❌ Decoding error: \(error)")
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("📄 Response JSON: \(jsonString)")
                    }
                    // Print detailed decoding error
                    if let decodingError = error as? DecodingError {
                        switch decodingError {
                        case .keyNotFound(let key, let context):
                            print("🔍 Missing key: \(key.stringValue) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                        case .typeMismatch(let type, let context):
                            print("🔍 Type mismatch for \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                            print("   Expected: \(type), context: \(context.debugDescription)")
                        case .valueNotFound(let type, let context):
                            print("🔍 Value not found for \(type) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                        case .dataCorrupted(let context):
                            print("🔍 Data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
                            print("   Debug: \(context.debugDescription)")
                        @unknown default:
                            print("🔍 Unknown decoding error")
                        }
                    }
                }
                throw NetworkError.decodingError(error)
            }
        }
    }
}

// MARK: - Error Types

enum NetworkError: LocalizedError {
    case invalidResponse
    case invalidURL
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .invalidURL:
            return "Invalid URL"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

// MARK: - Mock for Testing

#if DEBUG
final class MockNetworkService: NetworkServiceProtocol {
    // Mock properties for testing - marked as unsafe since they're mutable
    nonisolated(unsafe) var mockSession: QuizSession?
    nonisolated(unsafe) var mockResponse: QuizResponse?
    nonisolated(unsafe) var mockAudioData: Data?
    nonisolated(unsafe) var shouldFail = false

    func createSession(maxQuestions: Int, difficulty: String, language: String, category: String?) async throws -> QuizSession {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let session = mockSession else {
            throw NetworkError.invalidResponse
        }
        return session
    }

    func startQuiz(sessionId: String, excludedQuestionIds: [String] = []) async throws -> QuizResponse {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let response = mockResponse else {
            throw NetworkError.invalidResponse
        }
        return response
    }

    func submitVoiceAnswer(sessionId: String, audioData: Data, fileName: String) async throws -> QuizResponse {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let response = mockResponse else {
            throw NetworkError.invalidResponse
        }
        return response
    }

    func submitTextInput(sessionId: String, input: String, audio: Bool) async throws -> QuizResponse {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        guard let response = mockResponse else {
            throw NetworkError.invalidResponse
        }
        return response
    }

    func downloadAudio(from urlString: String) async throws -> Data {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        return mockAudioData ?? Data()
    }

    func endSession(sessionId: String) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }
}
#endif
