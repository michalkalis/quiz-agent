//
//  AnswerConfirmationCountdownTests.swift
//  HangsTests
//
//  #108B (founder car test 2026-07-16, variant D): the auto-confirm countdown
//  lives INSIDE the Confirm CTA — draining fill + mono "Ns" chip — replacing
//  the separate "Auto-confirming in Ns" bar. Why it matters: while driving,
//  the time left to intervene (re-record / edit) must be readable in the same
//  glance as the button that will fire. Presence-level assertions only
//  (Verification Altitude, #57).
//

@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("AnswerConfirmationView CTA Countdown Tests")
@MainActor
struct AnswerConfirmationCountdownTests {
    private func makeView(countdown: Int, enabled: Bool) -> AnswerConfirmationView {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            autoConfirmCountdown: countdown,
            autoConfirmEnabled: enabled,
            // #171 Track F: the window is 5 s now — the chip must read the
            // real budget, not a stale 10 s fill fraction.
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {}
        )
    }

    @Test("Active auto-confirm shows the seconds chip in the Confirm CTA")
    func activeCountdownShowsChip() throws {
        let tree = try makeView(countdown: 4, enabled: true).inspect()
        // Chip inside the CTA — the driver's glanceable remaining time
        #expect(throws: Never.self) { try tree.find(text: "4s") }
        // The old separate countdown row must be gone
        #expect(throws: (any Error).self) { try tree.find(text: "Auto-confirming in 4s") }
    }

    @Test("Disabled auto-confirm renders a plain Confirm CTA without a chip")
    func disabledCountdownHidesChip() throws {
        let tree = try makeView(countdown: 4, enabled: false).inspect()
        #expect(throws: (any Error).self) { try tree.find(text: "4s") }
        #expect(throws: Never.self) { try tree.find(text: "Confirm") }
    }

    /// WHY (#171 Track B): an empty field is now a legal answer — "no answer" —
    /// and Confirm is the only way off the sheet that reaches a result. Leaving
    /// it disabled (as it was, to stop confirmAnswer eating the answer) would
    /// strand a driver whose recording captured nothing.
    @Test("Empty answer keeps Confirm tappable and names the no-answer state")
    func emptyAnswerKeepsConfirmEnabled() throws {
        let view = AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {}
        )
        let tree = try view.inspect()
        #expect(throws: Never.self) { try tree.find(text: "Nothing heard") }
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.confirm").isDisabled() == false)
    }

    /// WHY (#171 Track I): an MCQ voice match grades the option VALUE, so the
    /// sheet must show which option that is — "A · Kocka" — or the driver
    /// cannot tell a mishearing from a correct match in the 5 s they have.
    @Test("An MCQ voice match renders the matched option line")
    func matchedOptionLineIsShown() throws {
        let view = AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Kocka"),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            matchedOption: "A · Kocka"
        )
        let tree = try view.inspect()
        #expect(throws: Never.self) { try tree.find(text: "A · Kocka") }
    }
}
