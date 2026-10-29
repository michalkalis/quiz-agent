//
//  PlayerRecap.swift
//  Hangs
//
//  #213.5: a saved recap from `GET /api/v1/me/recaps`
//  (`apps/quiz-agent/app/api/routes/me_recaps.py`, payload built in
//  `app/player_stats/recaps.py`). The server never recomputes a recap, so the
//  story reads the same every time it is played. `kind` and `player_type` are
//  plain strings: a recap kind this build does not know is left out.
//

import Foundation

nonisolated struct PlayerRecap: Decodable, Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case first, month, year
    }

    let id: String
    let kind: Kind?
    /// Local calendar date the period starts on, "YYYY-MM-DD".
    let periodStart: String
    var seen: Bool
    /// The unlocked cards of the period, in the server's order.
    let cards: [StatCard]
    /// night_owl, road_tripper, speedster, specialist, all_rounder or explorer.
    let playerType: String

    init(id: String, kind: Kind?, periodStart: String, seen: Bool, cards: [StatCard], playerType: String) {
        self.id = id
        self.kind = kind
        self.periodStart = periodStart
        self.seen = seen
        self.cards = cards
        self.playerType = playerType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try Kind(rawValue: container.decode(String.self, forKey: .kind))
        periodStart = try container.decode(String.self, forKey: .periodStart)
        seen = try container.decode(Bool.self, forKey: .seen)
        let payload = try container.decode(Payload.self, forKey: .payload)
        cards = payload.cards
        playerType = payload.playerType
    }

    /// Year and month of the period, from "YYYY-MM-DD".
    var period: (year: Int, month: Int)? {
        let parts = periodStart.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1 ... 12).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// "október", "říjen", "October": the month on its own, as a title says it.
    func monthName(locale: Locale) -> String? {
        guard let period else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: DateComponents(year: period.year, month: period.month, day: 1)) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = .gmt
        formatter.locale = locale
        formatter.dateFormat = "LLLL"
        return formatter.string(from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, seen, payload
        case periodStart = "period_start"
    }

    private struct Payload: Decodable {
        let cards: [StatCard]
        let playerType: String
        enum CodingKeys: String, CodingKey {
            case cards
            case playerType = "player_type"
        }
    }
}

nonisolated struct PlayerRecaps: Decodable, Sendable {
    let recaps: [PlayerRecap]
}

/// One slide of the recap story (canvas "Lišta a Profil", section 3).
nonisolated enum RecapSlide: Sendable, Equatable {
    case intro(answers: Int, minutes: Int)
    case card(kind: String, content: StatCardContent)
    case playerType(String)

    /// Cards worth a slide, in story order; the rest stay in the Profile.
    private static let highlights = ["best_category", "where", "when", "improvement", "best_streak", "fastest_slowest"]
    private static let maxCardSlides = 5

    /// Totals first, then up to five highlights, the player type last.
    /// Unknown kinds, categories outside the taxonomy and a falling score are
    /// left out: a recap only tells good news.
    static func story(for recap: PlayerRecap) -> [RecapSlide] {
        var slides: [RecapSlide] = []
        for card in recap.cards {
            if case let .totals(answers, minutes) = card.content {
                slides.append(.intro(answers: answers, minutes: minutes))
            }
        }
        let byKind = Dictionary(recap.cards.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let cards: [RecapSlide] = highlights.compactMap { kind in
            guard let content = byKind[kind]?.content, content != .unknown else { return nil }
            if let category = content.category, Config.categoryDisplayName(for: category) == nil { return nil }
            if case let .improvement(_, direction) = content, direction != "up" { return nil }
            return .card(kind: kind, content: content)
        }
        slides += cards.prefix(maxCardSlides)
        slides.append(.playerType(recap.playerType))
        return slides
    }
}
