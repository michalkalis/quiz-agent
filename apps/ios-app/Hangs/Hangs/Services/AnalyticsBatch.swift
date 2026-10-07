//
//  AnalyticsBatch.swift
//  Hangs
//
//  #51: the wire body of `POST /api/v1/analytics/events` —
//  `{"events": [{name, occurred_at, session_id?, properties}]}`.
//

import Foundation

nonisolated struct AnalyticsBatch: Encodable, Equatable, Sendable {
    struct Event: Encodable, Equatable, Sendable {
        let name: String
        let occurredAt: Date
        let sessionId: String?
        let properties: [String: AnalyticsValue]

        enum CodingKeys: String, CodingKey {
            case name
            case occurredAt = "occurred_at"
            case sessionId = "session_id"
            case properties
        }
    }

    let events: [Event]

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
