//
//  PlayerStats.swift
//  Hangs
//
//  #213: the player's stat cards from `GET /api/v1/me/stats`
//  (`apps/quiz-agent/app/api/routes/me_stats.py`, cards in
//  `app/player_stats/cards.py`). `kind`, `state` and `unit` are plain strings
//  on the server so a new card never breaks a live build: a kind this build
//  does not know decodes as `.unknown` and the Profile leaves it out.
//

import Foundation

nonisolated struct PlayerStats: Decodable, Sendable, Equatable {
    let cards: [StatCard]
    let firstRecapProgress: FirstRecapProgress

    enum CodingKeys: String, CodingKey {
        case cards
        case firstRecapProgress = "first_recap_progress"
    }
}

/// How far the player is from the first recap (60 answers on 3 days today).
nonisolated struct FirstRecapProgress: Decodable, Sendable, Equatable {
    let answers: Int
    let answersTarget: Int
    let days: Int
    let daysTarget: Int

    var isReached: Bool {
        answers >= answersTarget && days >= daysTarget
    }

    var answersLeft: Int {
        max(answersTarget - answers, 0)
    }

    var daysLeft: Int {
        max(daysTarget - days, 0)
    }

    enum CodingKeys: String, CodingKey {
        case answers
        case answersTarget = "answers_target"
        case days
        case daysTarget = "days_target"
    }
}

nonisolated struct StatCard: Decodable, Sendable, Equatable, Identifiable {
    /// What a locked card still needs, in the server's unit.
    nonisolated struct Progress: Decodable, Sendable, Equatable {
        let current: Int
        let target: Int
        /// "games", "answers", "days", "categories" — or one added later.
        let unit: String

        var remaining: Int {
            max(target - current, 0)
        }

        var fraction: Double {
            target > 0 ? min(Double(current) / Double(target), 1) : 0
        }
    }

    let kind: String
    let progress: Progress
    /// The card's numbers; nil while it is locked (the server sends no data).
    let content: StatCardContent?

    var id: String {
        kind
    }

    var isLocked: Bool {
        content == nil
    }

    enum CodingKeys: String, CodingKey {
        case kind, state, progress, data
    }

    init(kind: String, progress: Progress, content: StatCardContent?) {
        self.kind = kind
        self.progress = progress
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        progress = try container.decode(Progress.self, forKey: .progress)
        let unlocked = try container.decode(String.self, forKey: .state) == "unlocked"
        // A known kind whose numbers no longer decode reads as unknown, not as a
        // failed Profile.
        content = unlocked ? (try? StatCardContent(kind: kind, data: container.superDecoder(forKey: .data))) ?? .unknown : nil
    }
}

/// An unlocked card's numbers, one case per server card kind.
nonisolated enum StatCardContent: Sendable, Equatable {
    case totals(answers: Int, minutes: Int)
    case bestCategory(category: String, accuracy: Int)
    case weakestCategory(category: String, accuracy: Int)
    /// `place`: car, bluetooth, speaker, headphones or other.
    case whereYouPlay(place: String, share: Int)
    /// `partOfDay`: morning, afternoon, evening, night; `weekday`: monday…sunday.
    case whenYouPlay(partOfDay: String, weekday: String)
    case typicalQuiz(minutes: Double, answers: Int)
    /// `direction`: up, down or steady; points of accuracy at the same difficulty.
    case improvement(deltaPoints: Int, direction: String)
    case bestStreak(length: Int)
    case hardQuestions(answers: Int, accuracy: Int)
    /// `better`: mcq, open or even.
    case choiceVsOwnAnswer(choiceAccuracy: Int, ownAccuracy: Int, better: String)
    case fastestCategory(category: String, medianMs: Int)
    /// A kind this build does not know.
    case unknown

    init(kind: String, data decoder: Decoder) throws {
        switch kind {
        case "totals":
            let d = try Totals(from: decoder)
            self = .totals(answers: d.answers, minutes: d.minutes)
        case "best_category":
            let d = try Category(from: decoder)
            self = .bestCategory(category: d.category, accuracy: d.accuracy)
        case "weakest_category":
            let d = try Category(from: decoder)
            self = .weakestCategory(category: d.category, accuracy: d.accuracy)
        case "where":
            let d = try Where(from: decoder)
            self = .whereYouPlay(place: d.top, share: d.share)
        case "when":
            let d = try When(from: decoder)
            self = .whenYouPlay(partOfDay: d.partOfDay, weekday: d.weekday)
        case "typical_game":
            let d = try Typical(from: decoder)
            self = .typicalQuiz(minutes: d.minutes, answers: d.answers)
        case "improvement":
            let d = try Improvement(from: decoder)
            self = .improvement(deltaPoints: d.deltaPoints, direction: d.direction)
        case "best_streak":
            self = try .bestStreak(length: Streak(from: decoder).length)
        case "hard_questions":
            let d = try Hard(from: decoder)
            self = .hardQuestions(answers: d.answers, accuracy: d.accuracy)
        case "mcq_vs_open":
            let d = try ChoiceVsOwn(from: decoder)
            self = .choiceVsOwnAnswer(choiceAccuracy: d.mcq.accuracy, ownAccuracy: d.open.accuracy, better: d.better)
        case "fastest_slowest":
            let d = try Speed(from: decoder)
            self = .fastestCategory(category: d.fastest.category, medianMs: d.fastest.medianMs)
        default:
            self = .unknown
        }
    }

    /// The taxonomy category the card names, if any.
    var category: String? {
        switch self {
        case let .bestCategory(category, _), let .weakestCategory(category, _), let .fastestCategory(category, _):
            category
        default:
            nil
        }
    }

    private struct Totals: Decodable { let answers: Int; let minutes: Int }
    private struct Category: Decodable { let category: String; let accuracy: Int }
    private struct Where: Decodable { let top: String; let share: Int }
    private struct When: Decodable {
        let partOfDay: String
        let weekday: String
        enum CodingKeys: String, CodingKey { case partOfDay = "part_of_day", weekday }
    }

    private struct Typical: Decodable { let minutes: Double; let answers: Int }
    private struct Improvement: Decodable {
        let deltaPoints: Int
        let direction: String
        enum CodingKeys: String, CodingKey { case deltaPoints = "delta_points", direction }
    }

    private struct Streak: Decodable { let length: Int }
    private struct Hard: Decodable { let answers: Int; let accuracy: Int }
    private struct ChoiceVsOwn: Decodable {
        struct Side: Decodable { let accuracy: Int }
        let mcq: Side
        let open: Side
        let better: String
    }

    private struct Speed: Decodable {
        struct Entry: Decodable {
            let category: String
            let medianMs: Int
            enum CodingKeys: String, CodingKey { case category, medianMs = "median_ms" }
        }

        let fastest: Entry
    }
}
