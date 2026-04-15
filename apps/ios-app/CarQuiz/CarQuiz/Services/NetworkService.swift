//
//  NetworkService.swift
//  CarQuiz
//
//  REST API client for Quiz Agent backend
//  Actor-based for thread-safe networking
//

@preconcurrency import Foundation
import os

/// Protocol for network operations
protocol NetworkServiceProtocol: Sendable {
    func createSession(maxQuestions: Int, difficulty: String, language: String, category: String?, userId: String?) async throws -> QuizSession
    func startQuiz(sessionId: String, excludedQuestionIds: [String]) async throws -> QuizResponse
    func submitVoiceAnswer(sessionId: String, audioData: Data, fileName: String) async throws -> QuizResponse
    func submitTextInput(sessionId: String, input: String, audio: Bool) async throws -> QuizResponse
    func downloadAudio(from urlString: String) async throws -> Data
    func endSession(sessionId: String) async throws
    func extendSession(sessionId: String, minutes: Int) async throws
    func rateQuestion(sessionId: String, rating: Int) async throws
    func flagQuestion(sessionId: String, reason: String?) async throws
    func fetchElevenLabsToken() async throws -> String
    func getUsage(userId: String) async throws -> UsageInfo
    func setPremium(userId: String) async throws
}

/// Thread-safe network service using Swift 6 actor
actor NetworkService: NetworkServiceProtocol {
    private let baseURL: URL
    private let session: URLSession

    // Task registry for cancellation support
    private var activeTasks: [UUID: URLSessionDataTask] = [:]

    init(baseURL: String = Config.apiBaseURL) {
        guard let url = URL(string: baseURL) else {
            fatalError("NetworkService: invalid baseURL '\(baseURL)' — check Config.apiBaseURL")
        }
        self.baseURL = url

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

        Logger.network.debug("🌐 Cancelled task: \(id, privacy: .public)")
    }

    // MARK: - Session Management

    func createSession(maxQuestions: Int = 10, difficulty: String = "medium", language: String = "en", category: String? = nil, userId: String? = nil) async throws -> QuizSession {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions")

        let base = baseURL
        Logger.network.debug("🌐 Base URL: \(base, privacy: .public)")
        Logger.network.debug("🌐 Full endpoint: \(endpoint, privacy: .public)")

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

        // Add user_id for usage tracking (freemium)
        if let userId = userId {
            body["user_id"] = userId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public)")

        let (data, response) = try await session.data(for: request)

        Logger.network.debug("📥 Response received: \(data.count, privacy: .public) bytes")
        if let httpResponse = response as? HTTPURLResponse {
            Logger.network.debug("📊 Status code: \(httpResponse.statusCode, privacy: .public)")
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
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/start"), resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
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

        Logger.network.debug("🌐 POST \(url, privacy: .public) with \(excludedQuestionIds.count, privacy: .public) excluded IDs")

        let (data, response) = try await session.data(for: request)

        Logger.network.debug("📥 Response received: \(data.count, privacy: .public) bytes")
        if let httpResponse = response as? HTTPURLResponse {
            Logger.network.debug("📊 Status code: \(httpResponse.statusCode, privacy: .public)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        // Handle 429 daily limit reached
        if httpResponse.statusCode == 429 {
            if let limitError = try? JSONDecoder().decode(DailyLimitErrorWrapper.self, from: data) {
                throw NetworkError.dailyLimitReached(limitError.detail)
            }
            throw NetworkError.serverError(statusCode: 429, message: "Rate limited")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            Logger.network.error("❌ HTTP error: \(httpResponse.statusCode, privacy: .public)")
            if let responseString = String(data: data, encoding: .utf8) {
                Logger.network.error("📄 Response body: \(responseString, privacy: .public)")
            }
            throw NetworkError.invalidResponse
        }

        return try await decodeQuizResponse(from: data)
    }

    func endSession(sessionId: String) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"

        Logger.network.debug("🌐 DELETE \(endpoint, privacy: .public)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode

            Logger.network.error("❌ HTTP error: \(statusCode, privacy: .public)")
            if let responseString = String(data: data, encoding: .utf8) {
                Logger.network.error("📄 Response body: \(responseString, privacy: .public)")
            }

            if statusCode == 404 {
                throw NetworkError.sessionNotFound
            }

            // Try to extract error message from backend response
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw NetworkError.serverError(statusCode: statusCode, message: errorResponse.detail)
            }

            throw NetworkError.serverError(statusCode: statusCode, message: "Failed to end session (HTTP \(statusCode))")
        }
    }

    // MARK: - Session Extend

    func extendSession(sessionId: String, minutes: Int = 30) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/extend")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["minutes": minutes])

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (extend \(minutes, privacy: .public)min)")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }
    }

    // MARK: - Question Rating

    func rateQuestion(sessionId: String, rating: Int) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/rate")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["rating": rating])

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (rating: \(rating, privacy: .public))")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }
    }

    func flagQuestion(sessionId: String, reason: String?) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/flag")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [:]
        if let reason { body["reason"] = reason }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (flag)")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
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
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (audio: \(audioData.count, privacy: .public) bytes)")

        let (data, response) = try await session.data(for: request)

        Logger.network.debug("📥 Voice response received: \(data.count, privacy: .public) bytes")
        if let httpResponse = response as? HTTPURLResponse {
            Logger.network.debug("📊 Status code: \(httpResponse.statusCode, privacy: .public)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        // Handle 429 daily limit reached
        if httpResponse.statusCode == 429 {
            if let limitError = try? JSONDecoder().decode(DailyLimitErrorWrapper.self, from: data) {
                throw NetworkError.dailyLimitReached(limitError.detail)
            }
            throw NetworkError.serverError(statusCode: 429, message: "Rate limited")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode

            Logger.network.error("❌ HTTP error: \(statusCode, privacy: .public)")
            if let responseString = String(data: data, encoding: .utf8) {
                Logger.network.error("📄 Response body: \(responseString, privacy: .public)")
            }

            // Try to extract error message from backend response
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw NetworkError.serverError(statusCode: statusCode, message: errorResponse.detail)
            }

            throw NetworkError.invalidResponse
        }

        return try await decodeQuizResponse(from: data)
    }

    func submitTextInput(sessionId: String, input: String, audio: Bool = true) async throws -> QuizResponse {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/input"), resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
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

        Logger.network.debug("🌐 POST \(url, privacy: .public) (text: \(input.prefix(50), privacy: .public)...)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        // Handle 429 daily limit reached
        if httpResponse.statusCode == 429 {
            if let limitError = try? JSONDecoder().decode(DailyLimitErrorWrapper.self, from: data) {
                throw NetworkError.dailyLimitReached(limitError.detail)
            }
            throw NetworkError.serverError(statusCode: 429, message: "Rate limited")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
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

        Logger.network.debug("🌐 GET \(url, privacy: .public)")

        // IMPORTANT: Disable caching for audio downloads
        // Backend returns same URL for different questions, so we must bypass cache
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10  // Audio downloads should not block the quiz flow

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
                                Logger.network.warning("⚠️ Download size mismatch: expected \(expectedBytes, privacy: .public) bytes, got \(actualBytes, privacy: .public) bytes")
                                continuation.resume(throwing: NetworkError.invalidResponse)
                                return
                            }

                            Logger.network.debug("✓ Download integrity verified: \(actualBytes, privacy: .public) bytes")
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

    // MARK: - ElevenLabs Token

    func fetchElevenLabsToken() async throws -> String {
        let endpoint = baseURL.appendingPathComponent("/api/v1/elevenlabs/token")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (ElevenLabs token)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.network.error("❌ ElevenLabs token request failed: HTTP \(statusCode, privacy: .public)")
            throw NetworkError.serverError(statusCode: statusCode, message: "Failed to get ElevenLabs token")
        }

        struct TokenResponse: Decodable {
            let token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        Logger.network.info("✅ ElevenLabs token received")

        return tokenResponse.token
    }

    // MARK: - Usage / Freemium

    func getUsage(userId: String) async throws -> UsageInfo {
        let endpoint = baseURL.appendingPathComponent("/api/v1/usage/\(userId)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        Logger.network.debug("🌐 GET \(endpoint, privacy: .public)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(UsageInfo.self, from: data)
    }

    func setPremium(userId: String) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/usage/\(userId)/premium")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (set premium)")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
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
                Logger.network.error("❌ Decoding error: \(error, privacy: .public)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    Logger.network.error("📄 Response JSON: \(jsonString, privacy: .public)")
                }
                // Log detailed decoding error
                if let decodingError = error as? DecodingError {
                    switch decodingError {
                    case .keyNotFound(let key, let context):
                        Logger.network.error("🔍 Missing key: \(key.stringValue, privacy: .public) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                    case .typeMismatch(let type, let context):
                        Logger.network.error("🔍 Type mismatch for \(String(describing: type), privacy: .public) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                        Logger.network.error("   Expected: \(String(describing: type), privacy: .public), context: \(context.debugDescription, privacy: .public)")
                    case .valueNotFound(let type, let context):
                        Logger.network.error("🔍 Value not found for \(String(describing: type), privacy: .public) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                    case .dataCorrupted(let context):
                        Logger.network.error("🔍 Data corrupted at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                        Logger.network.error("   Debug: \(context.debugDescription, privacy: .public)")
                    @unknown default:
                        Logger.network.error("🔍 Unknown decoding error")
                    }
                }
                throw NetworkError.decodingError(error)
            }
        }
    }
}

// MARK: - Error Types

/// Backend error response structure
private struct ErrorResponse: Decodable {
    let detail: String
}

/// Backend 429 response wraps DailyLimitError in "detail" field
private struct DailyLimitErrorWrapper: Decodable {
    let detail: DailyLimitError
}

enum NetworkError: LocalizedError {
    case invalidResponse
    case invalidURL
    case decodingError(Error)
    case serverError(statusCode: Int, message: String)
    case dailyLimitReached(DailyLimitError)
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .invalidURL:
            return "Invalid URL"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .serverError(_, let message):
            return message
        case .dailyLimitReached:
            return "Daily question limit reached"
        case .sessionNotFound:
            return "Session not found or already ended"
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

    func createSession(maxQuestions: Int, difficulty: String, language: String, category: String?, userId: String?) async throws -> QuizSession {
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

    func extendSession(sessionId: String, minutes: Int) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func rateQuestion(sessionId: String, rating: Int) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func flagQuestion(sessionId: String, reason: String?) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }

    func fetchElevenLabsToken() async throws -> String {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        return "mock-elevenlabs-token"
    }

    func getUsage(userId: String) async throws -> UsageInfo {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
        return UsageInfo(
            userId: userId,
            isPremium: false,
            questionsUsed: 5,
            questionsLimit: 20,
            remaining: 15,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400))
        )
    }

    func setPremium(userId: String) async throws {
        if shouldFail {
            throw NetworkError.invalidResponse
        }
    }
}
#endif
