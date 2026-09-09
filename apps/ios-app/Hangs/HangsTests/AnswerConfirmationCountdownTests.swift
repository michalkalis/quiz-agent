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

    /// WHY (#171 Track D, kept through #173): "paused" has to be READABLE. A
    /// vanished countdown chip alone reads as "auto-confirm is off", not "the
    /// quiz is waiting for me" — the badge is what tells the driver nothing will
    /// happen until they act. The way back OUT is no longer on this sheet: #173
    /// decision 4 moved pause/resume to the quiz toolbar, so the sheet must
    /// report the state and offer no pause control of its own.
    @Test("A paused sheet names the state and hosts no pause control of its own")
    func pausedSheetShowsBadgeAndNoPauseControl() throws {
        let view = AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            // The presenter zeroes the countdown when it cancels auto-confirm,
            // so a paused sheet can never render a chip that is not ticking.
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            isPaused: true
        )
        let tree = try view.inspect()
        #expect(throws: Never.self) { try tree.find(text: "PAUSED") }
        // #173: neither label may appear here — the toolbar owns both.
        #expect(throws: (any Error).self) { try tree.find(text: "Continue") }
        #expect(throws: (any Error).self) { try tree.find(text: "Pause") }
        #expect(throws: (any Error).self) {
            try tree.find(viewWithAccessibilityIdentifier: "confirmation.pause")
        }
        // Confirm stays plain and tappable — confirming IS resuming.
        #expect(throws: Never.self) { try tree.find(text: "Confirm") }
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.confirm").isDisabled() == false)
    }

    /// WHY (#171 Track D review): the re-record lock exists for the instant the
    /// auto-confirm window RUNS OUT and the submit fires — not for a pause,
    /// which zeroes the same countdown with nothing in flight. Locking it there
    /// left a paused sheet with Confirm as its only exit, contradicting the
    /// rule that confirm / edit / re-record keep working while paused.
    @Test("A paused sheet keeps Re-record and Edit usable")
    func pausedSheetKeepsReRecordAndEditUsable() throws {
        let view = AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            isPaused: true
        )
        let tree = try view.inspect()
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled() == false)
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.edit").isDisabled() == false)
    }

    /// WHY: the lock itself must survive — a countdown that reached 0 while
    /// RUNNING means the answer is being submitted, and a second recording
    /// would race it (#108B).
    @Test("An expired countdown still locks Re-record when not paused")
    func expiredCountdownStillLocksReRecord() throws {
        let view = AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            isPaused: false
        )
        let tree = try view.inspect()
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled() == true)
    }

    /// WHY (#173 decision 4): a running sheet shows the live countdown and NO
    /// paused badge. The Pause pill it used to carry is gone — pause became a
    /// toolbar control so it works from every quiz state, not just this one
    /// screen; the spoken "pauza" still routes there.
    @Test("A running sheet counts down, shows no PAUSED badge and no pause pill")
    func runningSheetHasNoPausePill() throws {
        let view = AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            isPaused: false
        )
        let tree = try view.inspect()
        #expect(throws: (any Error).self) { try tree.find(text: "Pause") }
        #expect(throws: Never.self) { try tree.find(text: "4s") }
        #expect(throws: (any Error).self) { try tree.find(text: "PAUSED") }
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
