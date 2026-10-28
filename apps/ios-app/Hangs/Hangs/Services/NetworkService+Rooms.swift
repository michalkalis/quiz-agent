//
//  NetworkService+Rooms.swift
//  Hangs
//
//  #212: the room endpoints on the shared request pipeline (bearer, 401
//  refresh, error mapping). A 404/409 surfaces as `NetworkError.serverError`.
//

import Foundation

extension NetworkService: RoomServiceProtocol {
    func createRoom(sessionId: String, hostName: String, revealMode: RoomState.RevealMode, thinkingSeconds: Int) async throws -> RoomCreated {
        // `net_tickets` stays empty until the IPv4/IPv6 probe hostnames exist:
        // the server matches the Wi-Fi on the request's own address.
        let body: [String: Any] = [
            "session_id": sessionId,
            "host_name": hostName,
            "net_tickets": [String](),
            "reveal_mode": revealMode.rawValue,
            "thinking_seconds": thinkingSeconds,
        ]
        let data = try await roomRequest("POST", "/api/v1/rooms", endpoint: "/api/v1/rooms", body: body)
        return try JSONDecoder().decode(RoomCreated.self, from: data)
    }

    func nearbyRooms() async throws -> [NearbyRoom] {
        nonisolated struct Reply: Decodable { let rooms: [NearbyRoom] }
        let body: [String: Any] = ["net_tickets": [String]()]
        let data = try await roomRequest("POST", "/api/v1/rooms/nearby", endpoint: "/api/v1/rooms/nearby", body: body)
        return try JSONDecoder().decode(Reply.self, from: data).rooms
    }

    func joinRoom(_ invite: RoomInvite, displayName: String) async throws -> RoomState {
        var body: [String: Any] = ["display_name": displayName, "net_tickets": [String]()]
        switch invite {
        case let .nearby(room): body["room_id"] = room.roomId
        case let .token(token): body["join_token"] = token
        }
        let data = try await roomRequest("POST", "/api/v1/rooms/join", endpoint: "/api/v1/rooms/join", body: body)
        return try JSONDecoder().decode(RoomState.self, from: data)
    }

    func removePlayer(roomId: String, participantId: String) async throws {
        _ = try await roomRequest(
            "DELETE",
            "/api/v1/rooms/\(roomId)/players/\(participantId)",
            endpoint: "/api/v1/rooms/{id}/players/{pid}"
        )
    }

    func roomState(roomId: String, since: Int?) async throws -> RoomState {
        var query: [URLQueryItem] = []
        if let since { query.append(URLQueryItem(name: "since", value: String(since))) }
        let data = try await roomRequest(
            "GET",
            "/api/v1/rooms/\(roomId)/state",
            endpoint: "/api/v1/rooms/{id}/state",
            query: query,
            timeout: 5
        )
        return try JSONDecoder().decode(RoomState.self, from: data)
    }

    func openQuestion(roomId: String, questionId: String) async throws -> RoomState {
        let data = try await roomRequest(
            "POST",
            "/api/v1/rooms/\(roomId)/open",
            endpoint: "/api/v1/rooms/{id}/open",
            body: ["question_id": questionId]
        )
        return try JSONDecoder().decode(RoomState.self, from: data)
    }

    func answer(roomId: String, questionId: String, answer: String) async throws -> RoomState {
        let data = try await roomRequest(
            "POST",
            "/api/v1/rooms/\(roomId)/answer",
            endpoint: "/api/v1/rooms/{id}/answer",
            body: ["question_id": questionId, "answer": answer]
        )
        return try JSONDecoder().decode(RoomState.self, from: data)
    }

    func reportAway(roomId: String, questionId: String) async throws {
        _ = try await roomRequest(
            "POST",
            "/api/v1/rooms/\(roomId)/away",
            endpoint: "/api/v1/rooms/{id}/away",
            body: ["question_id": questionId]
        )
    }

    func nextQuestion(roomId: String) async throws -> RoomState {
        let data = try await roomRequest("POST", "/api/v1/rooms/\(roomId)/next", endpoint: "/api/v1/rooms/{id}/next")
        return try JSONDecoder().decode(RoomState.self, from: data)
    }

    private func roomRequest(
        _ method: String,
        _ path: String,
        endpoint: String,
        body: [String: Any]? = nil,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = 10
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await performRequestData(request, endpointPath: endpoint)
    }
}
