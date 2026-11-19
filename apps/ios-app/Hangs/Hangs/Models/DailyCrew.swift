//
//  DailyCrew.swift
//  Hangs
//
//  #239 — the daily crew: everyone the player swapped a daily challenge link
//  with, by rarity points this week. Mirrors `DailyCrew` / `DailyCrewMember`
//  in `apps/quiz-agent/app/daily_challenge/schemas.py`.
//

import Foundation

/// `GET /api/v1/daily-challenge/crew`. Empty `members` = no crew yet.
nonisolated struct DailyCrew: Codable, Sendable, Equatable {
    /// Monday of the week, `YYYY-MM-DD`.
    let weekStart: String
    /// Best first, the player included.
    let members: [DailyCrewMember]

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case members
    }
}

nonisolated struct DailyCrewMember: Codable, Sendable, Equatable, Identifiable {
    /// Opaque id to remove this person; nil on the player's own row.
    let memberId: String?
    /// Their name in the app; nil on the player's own row.
    let name: String?
    /// Rarity points from Monday to the day asked for.
    let points: Int
    /// Rarity points on the day asked for.
    let today: Int
    /// Days played this week.
    let days: Int
    /// 1 = most points; equal points share the place.
    let place: Int
    let isYou: Bool

    var id: String { memberId ?? "you" }

    enum CodingKeys: String, CodingKey {
        case name, points, today, days, place
        case memberId = "member_id"
        case isYou = "is_you"
    }
}
