//
//  NetworkService.swift
//  Hangs
//
//  REST API client for Quiz Agent backend
//  Actor-based for thread-safe networking
//

@preconcurrency import Foundation
import os
import Sentry

/// Protocol for network operations
protocol NetworkServiceProtocol: Sendable {
    func createSession(maxQuestions: Int, difficulty: String, language: String, categories: [String], userId: String?, includeImages: Bool, packId: String?) async throws -> QuizSession
    func startQuiz(sessionId: String, excludedQuestionIds: [String]) async throws -> QuizResponse
    func submitVoiceAnswer(sessionId: String, audioData: Data, fileName: String) async throws -> QuizResponse
    func submitTextInput(sessionId: String, input: String, audio: Bool) async throws -> QuizResponse
    /// In-app beta feedback (#109): multipart POST to `/feedback`. `message` is
    /// required; `metadataJSON`, `appVersion`, `screenshotPNG`, `audioWAV`, and
    /// `logsText` are optional attachments. `audioWAV` is the dictation recording
    /// (16 kHz mono PCM WAV) kept as a fallback when the transcript is wrong. Auth
    /// = same bearer as every other write path.
    func submitFeedback(message: String, metadataJSON: String?, appVersion: String?, screenshotPNG: Data?, audioWAV: Data?, logsText: String?) async throws
    func downloadAudio(from urlString: String) async throws -> Data
    func endSession(sessionId: String) async throws
    func extendSession(sessionId: String, minutes: Int) async throws
    func rateQuestion(sessionId: String, rating: Int) async throws
    func flagQuestion(sessionId: String, reason: String?) async throws
    func fetchElevenLabsToken() async throws -> String
    /// `GET /usage/me` — the backend derives the subject from the bearer, the
    /// same identity every write path (sessions, RC webhook grants, sync) is
    /// keyed on. Never pass a client-side id here: reading usage under the
    /// local deviceId while purchases land under the auth subject is exactly
    /// how paid state could never show up (#96 P1).
    func getUsage() async throws -> UsageInfo
    /// Purchase→webhook propagation bridge (issue #93): one-shot RC REST pull,
    /// called immediately after a successful SDK purchase, before re-fetching
    /// `/usage` — otherwise a just-paid user can still hit the 429 gate until
    /// the webhook mirror catches up.
    func syncEntitlements() async throws
}

/// Thread-safe network service using Swift 6 actor
actor NetworkService: NetworkServiceProtocol {
    private let baseURL: URL
    private let session: URLSession
    /// Server-trusted anonymous identity (#60). When present, every request
    /// carries `Authorization: Bearer <access>` and a 401 triggers a
    /// single-flight refresh + one retry. Nil in tests / before wiring → the
    /// request still goes out unauthenticated (legacy `user_id` grace path).
    private let authService: AuthServiceProtocol?

    init(baseURL: String = Config.apiBaseURL, session: URLSession? = nil, authService: AuthServiceProtocol? = nil) {
        guard let url = URL(string: baseURL) else {
            fatalError("NetworkService: invalid baseURL '\(baseURL)' — check Config.apiBaseURL")
        }
        self.baseURL = url
        self.authService = authService

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Authorized Request Helper

    /// Send a request with the anonymous bearer attached (when auth is wired).
    /// On a 401 it refreshes once (single-flight, deduped in `AuthService`),
    /// re-attaches the new bearer, and retries exactly once. Falls through to a
    /// plain send when no `authService` is present or no token is available, so
    /// the legacy `user_id` grace path keeps working through the staged rollout.
    private func sendAuthorized(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let authService else {
            return try await session.data(for: request)
        }

        var req = request
        let token = await authService.accessToken()
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)

        // Only retry on a 401 that followed a bearer we actually sent.
        guard let http = response as? HTTPURLResponse, http.statusCode == 401, let token else {
            return (data, response)
        }
        guard let fresh = await authService.refreshedAccessToken(replacing: token) else {
            return (data, response) // refresh unavailable → surface the 401
        }
        req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: req)
    }

    // MARK: - Sentry Breadcrumb Helpers (metadata only — no request/response bodies)

    private nonisolated func breadcrumbRequest(method: String, endpoint: String) {
        let crumb = Breadcrumb(level: .info, category: "network.request")
        crumb.message = "\(method) \(endpoint)"
        crumb.data = ["method": method, "endpoint": endpoint]
        SentryBreadcrumb.add(crumb)
    }

    private nonisolated func breadcrumbResponse(endpoint: String, status: Int, bytes: Int) {
        let level: SentryLevel = (200 ... 299).contains(status) ? .info : .warning
        let crumb = Breadcrumb(level: level, category: "network.response")
        crumb.message = "HTTP \(status) \(endpoint) (\(bytes)B)"
        crumb.data = ["status": status, "bytes": bytes, "endpoint": endpoint]
        SentryBreadcrumb.add(crumb)
    }

    private nonisolated func logHTTPError(endpoint: String, status: Int) {
        // Response body is NOT included — may contain user-generated data.
        SentryLog.error("HTTP error", category: .network, attributes: [
            "status": status,
            "endpoint": endpoint,
        ])
    }

    // MARK: - Generic Request Pipeline

    //
    // The shared middle every endpoint used to hand-roll: breadcrumb → send
    // with bearer/401-retry → HTTPURLResponse guard → body-discriminated 429
    // parse (QuotaLimitErrorWrapper → .quotaLimitReached; else
    // .serverError(429, "Rate limited")) → non-2xx ErrorResponse decode.
    //
    // Returns raw `Data` rather than decoding — callers own their own decode
    // (MainActor iso8601 for createSession/startQuiz/submitVoiceAnswer/
    // submitTextInput; plain decode for getUsage/fetchElevenLabsToken) so this
    // stays off the main actor and no decode is dragged onto it implicitly.

    private func performRequestData(_ request: URLRequest, endpointPath: String) async throws -> Data {
        breadcrumbRequest(method: request.httpMethod ?? "?", endpoint: endpointPath)

        let (data, response) = try await sendAuthorized(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        breadcrumbResponse(endpoint: endpointPath, status: httpResponse.statusCode, bytes: data.count)

        // Handle 429 daily limit reached
        if httpResponse.statusCode == 429 {
            logHTTPError(endpoint: endpointPath, status: 429)
            if let limitError = try? JSONDecoder().decode(QuotaLimitErrorWrapper.self, from: data) {
                throw NetworkError.quotaLimitReached(limitError.detail)
            }
            throw NetworkError.serverError(statusCode: 429, message: "Rate limited")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode
            Logger.network.error("❌ HTTP error: \(statusCode, privacy: .public)")
            if let responseString = String(data: data, encoding: .utf8) {
                Logger.network.error("📄 Response body: \(responseString, privacy: .public)")
            }
            logHTTPError(endpoint: endpointPath, status: statusCode)

            // Surface the backend's error detail (e.g. "question database is empty") instead of a generic message.
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw NetworkError.serverError(statusCode: statusCode, message: errorResponse.detail)
            }

            // Non-decodable body (edge-proxy error page, empty body): keep the
            // status code on the thrown error — callers hook on it (endSession's
            // 404 → sessionNotFound must hold for ANY 404, not only ones whose
            // body decodes as ErrorResponse).
            throw NetworkError.serverError(statusCode: statusCode, message: "HTTP \(statusCode)")
        }

        return data
    }

    /// Void variant for endpoints with no response body to decode.
    private func performRequest(_ request: URLRequest, endpointPath: String) async throws {
        _ = try await performRequestData(request, endpointPath: endpointPath)
    }

    // MARK: - Session Management

    func createSession(maxQuestions: Int = 10, difficulty: String = "medium", language: String = "en", categories: [String] = [], userId: String? = nil, includeImages: Bool = false, packId: String? = nil) async throws -> QuizSession {
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
            "language": language,
            "include_images": includeImages,
        ]

        // Add category filter if any selected (#82 item 4: multi-select list;
        // empty = all categories, omit the key entirely)
        if !categories.isEmpty {
            body["categories"] = categories
        }

        // Add user_id for usage tracking (freemium)
        if let userId = userId {
            body["user_id"] = userId
        }

        // Custom pack (#95): play a specific generated pack by id. The backend
        // sources questions from this pack and bypasses the free quota.
        if let packId {
            body["pack_id"] = packId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let endpointPath = "/api/v1/sessions"
        Logger.network.debug("🌐 POST \(endpoint, privacy: .public)")

        let data = try await performRequestData(request, endpointPath: endpointPath)

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
            "excluded_question_ids": excludedQuestionIds,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let endpointPath = "/api/v1/sessions/{id}/start"
        Logger.network.debug("🌐 POST \(url, privacy: .public) with \(excludedQuestionIds.count, privacy: .public) excluded IDs")

        let data = try await performRequestData(request, endpointPath: endpointPath)
        return try await decodeQuizResponse(from: data)
    }

    func endSession(sessionId: String) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"

        Logger.network.debug("🌐 DELETE \(endpoint, privacy: .public)")

        // 404 → sessionNotFound is a caller-side hook: the generic surfaces
        // .serverError(404, …) for EVERY 404 (decoded backend detail or not),
        // and this remaps it — every other status/error passes through unchanged.
        do {
            try await performRequest(request, endpointPath: "/api/v1/sessions/{id}")
        } catch let NetworkError.serverError(statusCode, _) where statusCode == 404 {
            throw NetworkError.sessionNotFound
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

        try await performRequest(request, endpointPath: "/api/v1/sessions/{id}/extend")
    }

    // MARK: - Question Rating

    func rateQuestion(sessionId: String, rating: Int) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/sessions/\(sessionId)/rate")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["rating": rating])

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (rating: \(rating, privacy: .public))")

        try await performRequest(request, endpointPath: "/api/v1/sessions/{id}/rate")
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

        try await performRequest(request, endpointPath: "/api/v1/sessions/{id}/flag")
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
        request.timeoutInterval = 120 // 2 minutes for AI processing

        // Build multipart form data
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        request.httpBody = body

        let endpointPath = "/api/v1/voice/submit/{id}"
        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (audio: \(audioData.count, privacy: .public) bytes)")

        let data = try await performRequestData(request, endpointPath: endpointPath)
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

        let endpointPath = "/api/v1/sessions/{id}/input"
        Logger.network.debug("🌐 POST \(url, privacy: .public) (text: \(input.prefix(50), privacy: .public)...)")
        // Breadcrumb: metadata only — do NOT include the text input (may be user answer).

        let data = try await performRequestData(request, endpointPath: endpointPath)
        return try await decodeQuizResponse(from: data)
    }

    // MARK: - Feedback (#109)

    func submitFeedback(message: String, metadataJSON: String?, appVersion: String?, screenshotPNG: Data?, audioWAV: Data?, logsText: String?) async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/feedback")

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // Multipart builder — same shape as submitVoiceAnswer, extended with
        // plain form fields and multiple file parts.
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        func appendFile(_ name: String, filename: String, contentType: String, data: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }

        appendField("message", message)
        if let metadataJSON { appendField("metadata", metadataJSON) }
        if let appVersion { appendField("app_version", appVersion) }
        if let screenshotPNG { appendFile("screenshot", filename: "screenshot.png", contentType: "image/png", data: screenshotPNG) }
        if let audioWAV, !audioWAV.isEmpty {
            appendFile("audio", filename: "feedback.wav", contentType: "audio/wav", data: audioWAV)
        }
        if let logsText, !logsText.isEmpty {
            appendFile("logs", filename: "hangs-logs.txt", contentType: "text/plain", data: Data(logsText.utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let endpointPath = "/api/v1/feedback"
        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (feedback: \(body.count, privacy: .public) bytes)")
        breadcrumbRequest(method: "POST", endpoint: endpointPath)

        let (data, response) = try await sendAuthorized(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        breadcrumbResponse(endpoint: endpointPath, status: httpResponse.statusCode, bytes: data.count)

        guard (200...299).contains(httpResponse.statusCode) else {
            logHTTPError(endpoint: endpointPath, status: httpResponse.statusCode)
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw NetworkError.serverError(statusCode: httpResponse.statusCode, message: errorResponse.detail)
            }
            throw NetworkError.invalidResponse
        }
    }

    // MARK: - Audio Download

    func downloadAudio(from urlString: String) async throws -> Data {
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
        request.timeoutInterval = 10 // Audio downloads should not block the quiz flow

        // Audio routes are auth-gated (require_auth_or_grace) — the request must
        // carry the bearer like every other endpoint, incl. the single-flight
        // 401-refresh-retry. Task cancellation propagates natively through
        // `session.data(for:)` (throws URLError(.cancelled)).
        let (data, response) = try await sendAuthorized(request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            if let status = (response as? HTTPURLResponse)?.statusCode {
                logHTTPError(endpoint: "audio-download", status: status)
            }
            throw NetworkError.invalidResponse
        }

        // Verify download integrity by checking Content-Length
        if let expectedLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let expectedBytes = Int64(expectedLength),
           expectedBytes > 0
        {
            let actualBytes = Int64(data.count)

            if actualBytes != expectedBytes {
                Logger.network.warning("⚠️ Download size mismatch: expected \(expectedBytes, privacy: .public) bytes, got \(actualBytes, privacy: .public) bytes")
                throw NetworkError.invalidResponse
            }

            Logger.network.debug("✓ Download integrity verified: \(actualBytes, privacy: .public) bytes")
        }

        return data
    }

    // MARK: - ElevenLabs Token

    func fetchElevenLabsToken() async throws -> String {
        let endpoint = baseURL.appendingPathComponent("/api/v1/elevenlabs/token")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public) (ElevenLabs token)")

        let data = try await performRequestData(request, endpointPath: "/api/v1/elevenlabs/token")

        struct TokenResponse: Decodable {
            let token: String
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        Logger.network.info("✅ ElevenLabs token received")

        return tokenResponse.token
    }

    // MARK: - Usage / Freemium

    func getUsage() async throws -> UsageInfo {
        let endpoint = baseURL.appendingPathComponent("/api/v1/usage/me")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        Logger.network.debug("🌐 GET \(endpoint, privacy: .public)")

        let data = try await performRequestData(request, endpointPath: "/api/v1/usage/me")

        let decoder = JSONDecoder()
        return try decoder.decode(UsageInfo.self, from: data)
    }

    func syncEntitlements() async throws {
        let endpoint = baseURL.appendingPathComponent("/api/v1/entitlements/sync")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15

        Logger.network.debug("🌐 POST \(endpoint, privacy: .public)")

        try await performRequest(request, endpointPath: "/api/v1/entitlements/sync")
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
                    case let .keyNotFound(key, context):
                        Logger.network.error("🔍 Missing key: \(key.stringValue, privacy: .public) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                    case let .typeMismatch(type, context):
                        Logger.network.error("🔍 Type mismatch for \(String(describing: type), privacy: .public) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                        Logger.network.error("   Expected: \(String(describing: type), privacy: .public), context: \(context.debugDescription, privacy: .public)")
                    case let .valueNotFound(type, context):
                        Logger.network.error("🔍 Value not found for \(String(describing: type), privacy: .public) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "), privacy: .public)")
                    case let .dataCorrupted(context):
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
private nonisolated struct ErrorResponse: Decodable, Sendable {
    let detail: String
}

/// Backend 429 response wraps QuotaLimitError in "detail" field
private nonisolated struct QuotaLimitErrorWrapper: Decodable, Sendable {
    let detail: QuotaLimitError
}

enum NetworkError: LocalizedError {
    case invalidResponse
    case invalidURL
    case decodingError(Error)
    case serverError(statusCode: Int, message: String)
    case quotaLimitReached(QuotaLimitError)
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid server response", comment: "Network error: server returned a malformed response")
        case .invalidURL:
            return String(localized: "Invalid URL", comment: "Network error: the request URL could not be built")
        case let .decodingError(error):
            return String(localized: "Failed to decode response: \(error.localizedDescription)", comment: "Network error: response body could not be decoded; placeholder is the underlying error")
        case let .serverError(_, message):
            // Server-provided message, already localized by the backend — do not wrap.
            return message
        case .quotaLimitReached:
            return String(localized: "Free question limit reached", comment: "Network error: user hit the free monthly question quota")
        case .sessionNotFound:
            return String(localized: "Session not found or already ended", comment: "Network error: the quiz session is no longer active")
        }
    }
}
