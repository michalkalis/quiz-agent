//
//  NetworkService+SharedQuiz.swift
//  Hangs
//
//  #232: the shared-quiz endpoints on the shared request pipeline (bearer,
//  401 refresh). A 404/409 surfaces as `NetworkError.sharedQuizUnavailable`.
//

import Foundation

extension NetworkService {
    func createSharedQuiz(sessionId: String?, packId: String?, displayName: String?) async throws -> SharedQuizCreated {
        var body: [String: Any] = [:]
        if let sessionId { body["session_id"] = sessionId }
        if let packId { body["pack_id"] = packId }
        if let displayName { body["display_name"] = displayName }
        let request = try sharedQuizRequest("POST", "/api/v1/shared-quizzes", body: body)
        let data = try await performRequestData(request, endpointPath: "/api/v1/shared-quizzes")
        return try JSONDecoder().decode(SharedQuizCreated.self, from: data)
    }

    func startSharedQuiz(token: String, displayName: String?) async throws -> SharedQuizStart {
        var body: [String: Any] = [:]
        if let displayName { body["display_name"] = displayName }
        var request = try sharedQuizRequest("POST", "/api/v1/shared-quizzes/\(token)/start", body: body)
        // Same headers as createSession: the server builds an ordinary quiz
        // session from this request.
        if BuildChannel.debugSurfacesEnabled() {
            request.setValue("testflight", forHTTPHeaderField: "X-Build-Channel")
        }
        request.setValue(Self.clientCapabilities, forHTTPHeaderField: "X-Client-Capabilities")
        let data = try await performRequestData(request, endpointPath: "/api/v1/shared-quizzes/{token}/start")
        return try await MainActor.run {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SharedQuizStart.self, from: data)
        }
    }

    func sharedQuizResults(token: String) async throws -> SharedQuizResults {
        let request = try sharedQuizRequest("GET", "/api/v1/shared-quizzes/\(token)/results", body: nil)
        let data = try await performRequestData(request, endpointPath: "/api/v1/shared-quizzes/{token}/results")
        return try JSONDecoder().decode(SharedQuizResults.self, from: data)
    }

    private func sharedQuizRequest(_ method: String, _ path: String, body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
