//
//  DailyRound.swift
//  Hangs
//
//  #205: the marker of a quiz round that plays the daily challenge. While it
//  is set the round reveals every answer at once (never at the end of the
//  set), keeps each answer's crowd strip for its result card, offers no
//  upsell and no "Play again" (one challenge a day), and ends on the daily
//  round end instead of the score screen.
//

import Foundation

struct DailyRound: Equatable {
    let day: DailyChallengeDay
    /// The quiz language the challenge was started in.
    let language: String
    /// The server's state as the start returned it; the round end refreshes it.
    var state: DailyChallengeState?
    /// The crowd strip of each answered question, by question id.
    var crowds: [String: CrowdStrip] = [:]
}
