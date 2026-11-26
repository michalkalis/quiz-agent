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
//      Lepšie skóre ako 64 % z 12 hráčov.
//      trubbo.app
//
//  #232 (daily text B): with a shared link, an invite line replaces
//  "trubbo.app". #249.6: the link itself is never inside this text; it goes
//  to the share sheet as its own item, so chat apps show a preview card
//  instead of turning a long string into a file.
//

import Foundation

nonisolated enum DailyShareText {
    static func make(
        day: DailyChallengeDay,
        language: String,
        marks: [Bool?],
        score: Int,
        total: Int,
        rank: String?,
        invite: Bool = false
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
        if invite {
            lines.append(SharedQuizMessage.dailyInvite(questionCount: total))
        } else {
            lines.append("trubbo.app")
        }
        return lines.joined(separator: "\n")
    }

    /// One mark per question: a short list is filled with unanswered ones.
    static func paddedMarks(_ marks: [Bool?], total: Int) -> [Bool?] {
        Array(marks.prefix(max(total, 0))) + Array(repeating: nil, count: max(total - marks.count, 0))
    }

    /// Hardcoded per quiz language, not from the string catalog: the catalog
    /// follows the interface language, the share text follows the quiz.
    static func challengeName(language: String) -> String {
        switch language {
        case "sk": "denná výzva"
        case "cs": "denní výzva"
        case "uk": "щоденний виклик"
        default: "daily challenge"
        }
    }
}
