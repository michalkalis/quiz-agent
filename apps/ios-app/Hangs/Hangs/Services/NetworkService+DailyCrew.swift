//
//  NetworkService+DailyCrew.swift
//  Hangs
//
//  #239: the daily crew endpoints on the shared request pipeline (bearer,
//  401 refresh). 404 while the daily challenge is off for this build.
//

import Foundation

extension NetworkService {
    func fetchDailyCrew(date: String, language: String) async throws -> DailyCrew {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("/api/v1/daily-challenge/crew"), resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "date", value: date),
            URLQueryItem(name: "language", value: language),
        ]
        guard let url = components.url else { throw NetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let data = try await performRequestData(request, endpointPath: "/api/v1/daily-challenge/crew")
        return try JSONDecoder().decode(DailyCrew.self, from: data)
    }

    func removeDailyCrewMember(memberId: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("/api/v1/daily-challenge/crew/\(memberId)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 15
        _ = try await performRequestData(request, endpointPath: "/api/v1/daily-challenge/crew/{member_id}")
    }
}
