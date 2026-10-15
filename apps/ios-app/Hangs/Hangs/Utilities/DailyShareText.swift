//
//  DailyShareText.swift
//  Hangs
//
//  #205.6: the text the daily round end shares. Plain text, no answers (so
//  nobody spoils the day's questions), in the quiz language because the rank
//  line arrives from the server in that language:
//
//      Trubbo · denná výzva 15. 10.
//      ✅✅❌✅✅ 4/5
//      Lepší ako 64 % z 12 hráčov.
//      trubbo.app
//

import Foundation

nonisolated enum DailyShareText {
    static func make(
        day: DailyChallengeDay,
        language: String,
        marks: [Bool?],
        score: Int,
        total: Int,
        rank: String?
    ) -> String {
        let tiles = paddedMarks(marks, total: total).map { mark in
            switch mark {
            case true?: "✅"
            case false?: "❌"
            case nil: "⬜"
            }
        }
        var lines = [
            "Trubbo · \(challengeName(language: language)) \(day.label(languageCode: language))",
            "\(tiles.joined()) \(score)/\(total)",
        ]
        if let rank, !rank.isEmpty { lines.append(rank) }
        lines.append("trubbo.app")
        return lines.joined(separator: "\n")
    }

    /// One mark per question: a short list is filled with unanswered ones.
    static func paddedMarks(_ marks: [Bool?], total: Int) -> [Bool?] {
        Array(marks.prefix(max(total, 0))) + Array(repeating: nil, count: max(total - marks.count, 0))
    }

    /// Hardcoded per quiz language, not from the string catalog: the catalog
    /// follows the interface language, the share text follows the quiz.
    private static func challengeName(language: String) -> String {
        switch language {
        case "sk": "denná výzva"
        case "cs": "denní výzva"
        default: "daily challenge"
        }
    }
}
