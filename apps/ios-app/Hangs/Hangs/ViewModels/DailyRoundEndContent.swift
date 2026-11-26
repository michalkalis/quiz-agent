//
//  DailyRoundEndContent.swift
//  Hangs
//
//  #205.5: what the daily round end shows. The server's summary wins; until
//  it arrives (the round just ended, or a fetch failed) the round as this
//  phone saw it stands in: its marks and score, without the crowd lines.
//

import Foundation
import UIKit

struct DailyRoundEndContent: Equatable {
    let marks: [Bool?]
    let score: Int
    let total: Int
    /// The server's crowd line; nil hides the card.
    let comparison: String?
    let bestHit: DailyBestHit?
    let shareText: String
    private let day: DailyChallengeDay
    private let language: String
    private let rank: String?

    init(state: DailyChallengeState?, localMarks: [Bool?], round: DailyRound) {
        let summary = state?.status == .played ? state?.summary : nil
        let total = summary?.total ?? state?.total ?? max(localMarks.count, DailyChallengeViewModel.setSize)
        let marks = DailyShareText.paddedMarks(summary?.marks ?? localMarks, total: total)
        let score = summary?.score ?? marks.count { $0 == true }
        self.marks = marks
        self.score = score
        self.total = total
        comparison = summary?.comparison
        bestHit = summary?.bestHit
        day = round.day
        language = state?.language ?? round.language
        rank = summary?.rank
        shareText = DailyShareText.make(day: day, language: language, marks: marks, score: score, total: total, rank: rank)
    }

    /// #232: the same text with an invite line; the link travels as its own
    /// share item (#249.6).
    var inviteText: String {
        DailyShareText.make(day: day, language: language, marks: marks, score: score, total: total, rank: rank, invite: true)
    }

    /// #249.6: the score card for the share sheet's link header.
    @MainActor func shareCard() -> UIImage? {
        DailyShareCardView.image(day: day, language: language, marks: marks, score: score, total: total)
    }
}
