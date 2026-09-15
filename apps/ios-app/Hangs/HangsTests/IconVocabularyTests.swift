//
//  IconVocabularyTests.swift
//  HangsTests
//
//  #179 D2 (founder 2026-09-15, variant A) — the icon audit's four
//  unifications. Each was a case of the SAME thing wearing two different
//  glyphs, or a glyph claiming a state it is not in:
//
//   1. retry is `arrow.clockwise` everywhere (the quiz error screen used the
//      counter-clockwise arrow, Home / packs / paywall the clockwise one);
//   2. "play the answer" is the outline `speaker.wave.2` on the result screen
//      AND in the set recap (playback is an action, not a state, so it never
//      takes the filled glyph);
//   3. error / offline glyphs are outline — colour already carries the alarm,
//      and a filled shape in this app means "switched on";
//   4. the pack glyph is the outline `shippingbox`.
//
//  These pin the four names WHERE THEY RENDER, so a future "make it pop" edit
//  that reintroduces a filled variant fails here instead of in TestFlight.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
private func glyphNames(_ tree: InspectableView<some BaseViewType>) -> [String] {
    tree.findAll(ViewType.Image.self).compactMap { try? $0.actualImage().name() }
}

@MainActor
@Suite("Icon vocabulary — the #179 D2 unifications")
struct IconVocabularyTests {
    // MARK: - 1. Retry

    /// The quiz error screen is the one place a driver retries a failed
    /// operation; Home, My packs and the paywall already used `arrow.clockwise`
    /// for exactly that. One retry, one arrow.
    @Test("the error screen's Try Again carries the same retry arrow as Home")
    func retryArrowIsClockwise() async throws {
        let model = AppErrorModel(
            title: "Something went wrong",
            description: "Check your connection.",
            retryAction: .retryOperation
        )
        let view = ErrorView(viewModel: Fixtures.makeViewModel(), model: model)
        try await ViewHosting.host(view) {
            let names = try glyphNames(view.inspect())
            #expect(names.contains("arrow.clockwise"), "retry glyph drifted: \(names)")
            #expect(!names.contains("arrow.counterclockwise"),
                    "the counter-clockwise arrow is the REPLAY glyph, not retry")
        }
    }

    /// 3. …and the error screen's own alarm glyph stays outline.
    @Test("the error screen's alarm glyph is the outline triangle")
    func errorGlyphIsOutline() async throws {
        let model = AppErrorModel(
            title: "Something went wrong",
            description: "Check your connection.",
            retryAction: .retryOperation
        )
        let view = ErrorView(viewModel: Fixtures.makeViewModel(), model: model)
        try await ViewHosting.host(view) {
            let names = try glyphNames(view.inspect())
            #expect(!names.contains("exclamationmark.triangle.fill"),
                    "an error is not a switched-on state — colour carries it: \(names)")
        }
    }

    // MARK: - 2. Play the answer

    /// Result screen and set recap offer the same action ("hear it") and used to
    /// draw it with a filled speaker in one place and an outline one in the
    /// other. The outline wins: a fill here would read as "sound is on", which
    /// is the mute toggle's meaning two taps away in the toolbar.
    @Test("the result screen's hear-it glyph is the outline speaker")
    func resultHearItIsOutlineSpeaker() async throws {
        let panel = ResultAnswerPanel(
            answerLabel: "the answer",
            answerText: "Liechtenstein",
            isRecap: false,
            explanation: "It has had no standing army since 1868.",
            onHearIt: {}
        )
        try await ViewHosting.host(panel) {
            let hearIt = try panel.inspect().find(viewWithAccessibilityIdentifier: "result.hearIt")
            #expect(glyphNames(hearIt).contains("speaker.wave.2"))
        }
    }

    @Test("the set recap's hear-it glyph is the SAME outline speaker")
    func recapHearItIsOutlineSpeaker() async throws {
        let question = Fixtures.makeQuestion(text: "Which European state has no army?")
        let row = SetRecapRow(
            entry: RecapEntry(
                number: 1,
                question: question,
                evaluation: Evaluation(
                    userAnswer: "Malta",
                    result: .incorrect,
                    points: 0,
                    correctAnswer: "Liechtenstein",
                    questionId: question.id,
                    explanation: "It has had no standing army since 1868.",
                    headlineAnswer: nil
                )
            ),
            isExpanded: true,
            hearItDisabled: false,
            onToggle: {},
            onHearIt: {},
            onOpenSource: { _ in }
        )
        try await ViewHosting.host(row) {
            let hearIt = try row.inspect().find(viewWithAccessibilityIdentifier: "recap.row.1.hearIt")
            let names = glyphNames(hearIt)
            #expect(names.contains("speaker.wave.2"), "recap hear-it glyph drifted: \(names)")
            #expect(!names.contains("speaker.wave.2.fill"),
                    "the recap must not disagree with the result screen")
        }
    }

    // MARK: - 4. Pack glyph (and the outline alarm on the same card)

    @Test("the pack-credit chip uses the outline shippingbox")
    func packGlyphIsOutline() async throws {
        // The chip belongs to the subscriber-with-credits state (#93).
        let view = HomePlanCard(usage: makeUsage(premium: true, credits: 40, status: "active"))
        try await ViewHosting.host(view) {
            let chip = try view.inspect().find(viewWithAccessibilityIdentifier: "home.planCreditChip")
            let names = glyphNames(chip)
            #expect(names.contains("shippingbox"), "pack glyph drifted: \(names)")
        }
    }

    @Test("the renewal-failed pill uses the outline triangle")
    func gracePillGlyphIsOutline() async throws {
        let view = HomePlanCard(usage: makeUsage(premium: true, status: "grace"))
        try await ViewHosting.host(view) {
            let names = try glyphNames(view.inspect())
            #expect(names.contains("exclamationmark.triangle"), "grace pill glyph drifted: \(names)")
            #expect(!names.contains("exclamationmark.triangle.fill"))
        }
    }

    private func makeUsage(premium: Bool = false, credits: Int = 0, status: String? = nil) -> UsageInfo {
        UsageInfo(
            userId: "test-subject",
            isPremium: premium,
            questionsUsed: premium ? 0 : 30,
            questionsLimit: premium ? nil : 100,
            remaining: premium ? nil : 70,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(12 * 86400)),
            subscriptionStatus: status ?? (premium ? "active" : "none"),
            creditBalance: credits
        )
    }
}
