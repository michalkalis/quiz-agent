//
//  QuestionStemAutoScroll.swift
//  Hangs
//
//  TF build 53 feedback: a long question stem drifts to its end after a short
//  beat, so a driver reads the whole question hands-free. The pacing lives here
//  (#194 A1) so a restyled QuestionView keeps it.
//

import Foundation

enum QuestionStemAutoScroll {
    /// How long the top of the stem stays put before the drift starts.
    static let readingBeat: Duration = .seconds(3)

    /// Reading pace: 28 pt per second, never faster than 2 s overall.
    static func driftDuration(overflow: CGFloat) -> Double {
        max(2, Double(overflow) / 28)
    }
}
