//
//  AnswerConfirmationLayoutTests.swift
//  HangsTests
//
//  #174 A1 + B1 (founder, 2026-09-08 TestFlight): the confirmation sheet was
//  painted in the page colour and its two CTAs shared one 50/50 row, so the
//  sheet read as more screen and the Slovak "Vyhodnocujem…" shrank and
//  truncated the instant the driver pressed Confirm.
//  #208.6 (founder 2026-10-16) brings the row back on purpose: Again and
//  Confirm side by side, the same size, Again on the left. The titles scale
//  down on one line now (`HangsButtonTitle`), never truncate.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import UIKit
import ViewInspector

@MainActor
@Suite("Answer confirmation — elevated surface + one equal footer row (#174, #208.6)")
struct AnswerConfirmationLayoutTests {
    private func makeSheet(evaluating: String? = nil) -> AnswerConfirmationView {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            // A live window: 0 would trip the separate "submit is firing" lock on
            // Re-record and blur what this suite measures.
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            evaluatingAnswer: evaluating
        )
    }

    private func brightness(_ color: UIColor) -> CGFloat {
        var white: CGFloat = 0
        color.getWhite(&white, alpha: nil)
        return white
    }

    /// A1, and the founder's exact complaint: the sheet used `bg`, the same token
    /// the quiz screen paints itself with, so nothing said a layer had opened.
    /// `AnswerConfirmationView.surface` feeds BOTH the presentation background
    /// and the content ground, so pinning it here pins the whole sheet.
    @Test("the sheet surface is a distinct, elevated plane — never the page colour")
    func sheetSurfaceIsElevated() {
        #expect(AnswerConfirmationView.surface != Theme.Hangs.Colors.bg,
                "a sheet in the page colour is the bug this fixes")

        for style in [UIUserInterfaceStyle.dark, .light] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let sheet = UIColor(AnswerConfirmationView.surface).resolvedColor(with: traits)
            let screen = UIColor(Theme.Hangs.Colors.bg).resolvedColor(with: traits)
            #expect(brightness(sheet) > brightness(screen),
                    "the sheet must sit ABOVE the screen (HIG elevation) in \(style == .dark ? "dark" : "light") mode")
        }
    }

    /// #208.6: Again left, Confirm right, in both states — a footer that
    /// re-splits between Confirm and Processing… is the layout jump #174 fixed.
    /// `findAll` walks in render order, so the identifiers' relative positions
    /// ARE the row order.
    @Test("the footer is one row, Again before Confirm, in both states")
    func footerIsOneRowAgainFirst() throws {
        let expected = ["confirmation.reRecord", "confirmation.confirm"]
        let states: [String?] = [nil, "Paris"]
        for evaluating in states {
            let tree = try makeSheet(evaluating: evaluating).inspect()
            let row = try tree.find(ViewType.HStack.self, where: { stack in
                (try? stack.find(viewWithAccessibilityIdentifier: "confirmation.reRecord")) != nil
                    && (try? stack.find(viewWithAccessibilityIdentifier: "confirmation.confirm")) != nil
            })
            let order = row.findAll(where: { view in
                guard let id = try? view.accessibilityIdentifier() else { return false }
                return expected.contains(id)
            }).compactMap { try? $0.accessibilityIdentifier() }
            #expect(order == expected,
                    "footer order drifted (evaluating: \(evaluating ?? "no")): \(order)")
        }
    }

    /// The founder asked for two EQUAL buttons: both full-width capsules of
    /// the same height, so the row splits in half. A ghost "Again" under the
    /// CTA was the old, unequal pair.
    @Test("Again and Confirm are the same size of capsule")
    func againAndConfirmAreEqual() throws {
        let tree = try makeSheet().inspect()
        let again = try tree.find(HangsSecondaryButton.self).actualView()
        let confirm = try tree.find(HangsPrimaryButton.self).actualView()
        #expect(again.height == confirm.height)
        #expect(throws: (any Error).self, "no ghost link left on the sheet") {
            try tree.find(HangsGhostButton.self)
        }
    }

    /// The secondary action must go dead while the answer is graded — a live
    /// Re-record there cancels the in-flight submission mid-grade (#133 V14) —
    /// but it must stay on screen, or the footer height changes under the driver.
    @Test("Re-record stays present and goes disabled while evaluating")
    func reRecordIsPresentButDisabledWhileEvaluating() throws {
        let idle = try makeSheet().inspect()
        #expect(try idle.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled() == false)

        let evaluating = try makeSheet(evaluating: "Paris").inspect()
        #expect(try evaluating.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled())
    }
}
