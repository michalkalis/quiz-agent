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
//    can be asserted deterministically here; the picker wiring (tap schedules,
//    voice-match onChange cancels) is covered by the hosted inspector tests.
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

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(fired == 0)
    }

    @Test("without cancel the submit fires exactly once")
    func firesOnceWithoutCancel() async throws {
        var fired = 0
        let submit = MCQDelayedSubmit()
        submit.schedule(delayNs: 50_000_000) { fired += 1 }

        // Poll up to ~2s — timer resolution under TSan is too coarse for a fixed wait.
        for _ in 0 ..< 100 where fired == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(fired == 1)

        // And never a second fire.
        try await Task.sleep(nanoseconds: 200_000_000)
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
    @Test("voice match during the tap delay cancels the pending tap submit")
    func voiceMatchCancelsPendingTapSubmit() async throws {
        var selectCount = 0
        let view = MCQOptionPicker(
            options: testOptions,
            onSelect: { _, _ in selectCount += 1 }
        )

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Tap option A — schedules the delayed submit
            try tree.find(ViewType.Button.self).tap()
            // Voice match lands before the 500ms delay elapses; the VM submits it
            // itself, so the picker must cancel its pending tap submit.
            try tree.find(ViewType.VStack.self).callOnChange(oldValue: String?.none, newValue: "b" as String?)

            try await Task.sleep(nanoseconds: 900_000_000)
            #expect(selectCount == 0)
        }
    }

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

            // Poll up to ~3s — the 500ms delayed submit can overshoot a fixed
            // wait under TSan + parallel-suite load (same pattern as
            // firesOnceWithoutCancel above).
            for _ in 0 ..< 150 where selectCount == 0 {
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
    @Test("tap then voice-match submits and highlights the same key (no divergence)")
    func tapThenVoiceMatchSubmitsAndHighlightsSameKey() async throws {
        var selected: (key: String, value: String)?
        let box = KeyBox()
        let binding = Binding<String?>(get: { box.key }, set: { box.key = $0 })
        let view = MCQOptionPicker(
            options: testOptions,
            onSelect: { key, value in selected = (key, value) },
            externalSelectedKey: binding
        )

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // Tap option A — writes "a" into the single owned key (highlight)
            // and schedules its delayed submit.
            try tree.find(ViewType.Button.self).tap()
            #expect(box.key == "a")

            // Voice match on B lands before the tap's delay elapses. In
            // production the VM writes the same `mcqVoiceMatchedKey` the tap
            // just wrote — an other-source supersede — which must cancel A's
            // pending submit.
            box.key = "b"
            try tree.find(ViewType.VStack.self).callOnChange(oldValue: "a" as String?, newValue: "b" as String?)

            try await Task.sleep(nanoseconds: 900_000_000)
            #expect(selected == nil) // A's delayed submit never fired
            #expect(box.key == "b") // highlighted key == the voice-matched key — no divergence
        }
    }

    @Test("a tap's own echo does not cancel its own pending submit")
    func tapEchoDoesNotCancelOwnSubmit() async throws {
        var selected: (key: String, value: String)?
        let box = KeyBox()
        let binding = Binding<String?>(get: { box.key }, set: { box.key = $0 })
        let view = MCQOptionPicker(
            options: testOptions,
            onSelect: { key, value in selected = (key, value) },
            externalSelectedKey: binding
        )

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()
            #expect(box.key == "a")

            // The tap wrote "a" into the same bound key onChange watches — its
            // own echo (#110 T4 cancel-semantics rework). This must NOT cancel
            // the submit the tap itself just scheduled.
            try tree.find(ViewType.VStack.self).callOnChange(oldValue: String?.none, newValue: "a" as String?)

            // Poll up to ~3s, same pattern as tapSubmitsOnceWithoutVoiceMatch above.
            for _ in 0 ..< 150 where selected == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(selected?.key == "a")
        }
    }
}
