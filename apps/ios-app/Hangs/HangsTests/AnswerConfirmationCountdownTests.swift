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
            autoConfirmTotal: 10,
            onConfirm: {},
            onReRecord: {}
        )
    }

    @Test("Active auto-confirm shows the seconds chip in the Confirm CTA")
    func activeCountdownShowsChip() throws {
        let tree = try makeView(countdown: 7, enabled: true).inspect()
        // Chip inside the CTA — the driver's glanceable remaining time
        #expect(throws: Never.self) { try tree.find(text: "7s") }
        // The old separate countdown row must be gone
        #expect(throws: (any Error).self) { try tree.find(text: "Auto-confirming in 7s") }
    }

    @Test("Disabled auto-confirm renders a plain Confirm CTA without a chip")
    func disabledCountdownHidesChip() throws {
        let tree = try makeView(countdown: 7, enabled: false).inspect()
        #expect(throws: (any Error).self) { try tree.find(text: "7s") }
        #expect(throws: Never.self) { try tree.find(text: "Confirm") }
    }
}
