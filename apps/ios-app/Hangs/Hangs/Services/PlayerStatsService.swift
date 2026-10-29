//
//  PlayerStatsService.swift
//  Hangs
//
//  #213: `GET /api/v1/me/stats` on the shared request pipeline (bearer,
//  401 refresh, error mapping). The server needs a verified bearer, so a
//  player whose anonymous identity is not minted yet gets an error, and the
//  Profile offers Retry.
//

import Foundation

protocol PlayerStatsServiceProtocol: Sendable {
    func fetchPlayerStats() async throws -> PlayerStats
}

extension NetworkService: PlayerStatsServiceProtocol {
    func fetchPlayerStats() async throws -> PlayerStats {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/me/stats"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let data = try await performRequestData(request, endpointPath: "/api/v1/me/stats")
        return try JSONDecoder().decode(PlayerStats.self, from: data)
    }
}
