//
//  MCQOptionPickerRaceTests.swift
//  HangsTests
//
//  #54 task 54.16 — tap/voice-match race in MCQOptionPicker.
//
//  Why these tests matter:
//  - A tap schedules onSelect after a 500ms delay. A voice match arriving inside
//    that window is submitted by the ViewModel directly — if the pending tap task
//    is not cancelled, onSelect fires too and the answer submits twice.
//  - The race guard lives in MCQDelayedSubmit (a reference type) precisely so it
//    can be asserted deterministically here — including which key changes
//    cancel (`supersede(with:)`). The hosted inspector tests cover the tap side
//    only: since ViewInspector 0.10.4 a tap and a `callOnChange` on the hosted
//    picker resolve its @State to two different MCQDelayedSubmit instances, so
//    a hosted cancel assertion can no longer reach the submit the tap scheduled.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - MCQDelayedSubmit (race guard) — deterministic

@Suite("MCQDelayedSubmit single-submit guard (54.16)")
@MainActor
struct MCQDelayedSubmitTests {
    @Test("cancel before the delay elapses suppresses the submit")
    func cancelSuppressesFire() async throws {
        var fired = 0
        let submit = MCQDelayedSubmit()
        submit.schedule(delayNs: 50_000_000) { fired += 1 }
        submit.cancel()

        // Real time on purpose: MCQDelayedSubmit's delay is a VIEW-level timer
        // (#180 track A keeps views off the injected clock), and proving the
        // cancel SUPPRESSED the fire means outliving that delay.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired == 0)
    }

    @Test("without cancel the submit fires exactly once")
    func firesOnceWithoutCancel() async throws {
        var fired = 0
        let submit = MCQDelayedSubmit()
        submit.schedule(delayNs: 50_000_000) { fired += 1 }

        // View-level delay ⇒ real time; bound generously (~6 s ceiling) so a
        // loaded parallel run cannot starve it. Exits as soon as it fires.
        for _ in 0 ..< 300 where fired == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(fired == 1)

        // And never a second fire.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired == 1)
    }

    /// A voice match lands inside the tap's delay: the VM submits it itself, so
    /// the tap's pending submit must die or the answer goes in twice.
    @Test("a voice match on another key cancels the pending tap submit")
    func otherKeySupersedeCancels() async throws {
        var fired = 0
        let submit = MCQDelayedSubmit()
        submit.schedule(key: "a", delayNs: 50_000_000) { fired += 1 }
        submit.supersede(with: "b")

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired == 0)
    }

    /// The tap writes its key into the same binding onChange watches (#110 T4),
    /// and the VM clears the key to nil on a new question. Neither is a voice
    /// match, so neither may cancel the submit the tap just scheduled.
    @Test("the tap's own echo and a nil reset do not cancel", arguments: ["a", nil] as [String?])
    func echoAndResetDoNotCancel(newKey: String?) async throws {
        var fired = 0
        let submit = MCQDelayedSubmit()
        submit.schedule(key: "a", delayNs: 50_000_000) { fired += 1 }
        submit.supersede(with: newKey)

        for _ in 0 ..< 300 where fired == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(fired == 1)
    }
}

// MARK: - Picker wiring — hosted

private let testOptions = [
    (key: "a", value: "Mars"),
    (key: "b", value: "Jupiter"),
]

@Suite("MCQOptionPicker tap/voice race wiring (54.16)")
@MainActor
struct MCQOptionPickerRaceTests {
    @Test("tap with no voice match still submits exactly once after the delay")
    func tapSubmitsOnceWithoutVoiceMatch() async throws {
        var selectCount = 0
        let view = MCQOptionPicker(
            options: testOptions,
            onSelect: { _, _ in selectCount += 1 }
        )

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()

            // View-level delay ⇒ real time, bound generously (~10 s ceiling) so
            // TSan + parallel-suite load cannot starve it.
            for _ in 0 ..< 500 where selectCount == 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(selectCount == 1)
        }
    }
}

// MARK: - Single VM owner (#110 T4) — real binding, tap and voice converge

/// A plain reference box backing a manual `Binding` (get/set closures) so these
/// tests can write "the VM key" the same way `QuestionView` binds
/// `$viewModel.mcqVoiceMatchedKey` — without needing a full `QuizViewModel`.
@MainActor
private final class KeyBox {
    var key: String?
}

@Suite("MCQOptionPicker single VM owner (#110 T4)")
@MainActor
struct MCQOptionPickerSingleOwnerTests {
    /// The highlight and the submit read ONE key: the tap writes it through the
    /// VM binding instead of a view-local copy, so a later voice match that
    /// rewrites that key is what the screen shows (no divergence). Which key
    /// changes cancel the tap's submit is pinned on MCQDelayedSubmit above.
    @Test("a tap writes its key into the single VM-owned binding")
    func tapWritesTheOwnedKey() async throws {
        let box = KeyBox()
        let binding = Binding<String?>(get: { box.key }, set: { box.key = $0 })
        let view = MCQOptionPicker(
            options: testOptions,
            onSelect: { _, _ in },
            externalSelectedKey: binding
        )

        try await ViewHosting.host(view) {
            try view.inspect().find(ViewType.Button.self).tap()
            #expect(box.key == "a")
        }
    }
}
