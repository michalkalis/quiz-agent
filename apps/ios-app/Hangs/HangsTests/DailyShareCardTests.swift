//
//  DailyShareCardTests.swift
//  HangsTests
//
//  #249.6: the score card a shared daily result carries. Why each rule
//  matters:
//  - the picture is exactly 1200 x 630 px: that is the size chat apps expect
//    and the size the server's card (the friend's preview) has, so both look
//    alike;
//  - the share sheet gets text and link as two items: a String with the link
//    inside is what some chat apps turn into a .txt file;
//  - the card is the same for the same result (no randomness) and differs per
//    result, since it IS the message in a chat.
//

import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import Hangs

@Suite("Daily share card (#249.6)")
@MainActor
struct DailyShareCardTests {
    private let day = DailyChallengeDay(year: 2026, month: 11, day: 26)
    private let marks: [Bool?] = [true, true, false, true, true]

    private func card(_ language: String, marks: [Bool?]? = nil, score: Int = 4) -> some View {
        DailyShareCardView(day: day, language: language, marks: marks ?? self.marks, score: score, total: 5)
    }

    @Test("the picture is 1200 x 630 pixels")
    func size() throws {
        let image = try #require(DailyShareCardView.image(day: day, language: "sk", marks: marks, score: 4, total: 5))
        #expect(image.size.width * image.scale == 1200)
        #expect(image.size.height * image.scale == 630)
    }

    @Test("a different result draws a different picture")
    func differsPerResult() throws {
        let four = try #require(DailyShareCardView.image(day: day, language: "sk", marks: marks, score: 4, total: 5))
        let two = try #require(DailyShareCardView.image(day: day, language: "sk", marks: [true, true, false, false, false], score: 2, total: 5))
        #expect(four.pngData() != two.pngData())
    }

    @Test("the hook follows the quiz language")
    func hook() {
        #expect(DailyShareCardView.hook(language: "sk") == "Dáš viac?")
        #expect(DailyShareCardView.hook(language: "cs") == "Dáš víc?")
        #expect(DailyShareCardView.hook(language: "uk") == "Зможеш більше?")
        #expect(DailyShareCardView.hook(language: "en") == "Can you beat it?")
    }

    @Test("the round end's content builds the card from the played result")
    func contentBuildsCard() {
        let content = DailyRoundEndContent(state: nil, localMarks: marks, round: DailyRound(day: day, language: "sk"))
        #expect(content.shareCard() != nil)
        #expect(!content.inviteText.contains("https://"))
    }

    @Test(
        "pixels",
        .enabled(if: SnapshotBaseline.runtimeMatches, "pixel baselines were recorded on iOS \(SnapshotBaseline.iosVersion)"),
        arguments: ["sk", "uk"]
    )
    func pixels(language: String) {
        assertSnapshot(
            of: card(language),
            as: .image(layout: .fixed(width: 1200, height: 630), traits: UITraitCollection(displayScale: 1)),
            named: "card-\(language)"
        )
    }
}
