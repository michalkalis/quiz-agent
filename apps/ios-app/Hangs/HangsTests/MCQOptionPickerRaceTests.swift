//
//  MCQOptionPickerRaceTests.swift
//  HangsTests
//
//  #54 task 54.16 — tap/voice-match race in MCQOptionPicker.
//
//  Why these tests matter: a tap is the driver's answer and must reach the view
//  model AT the tap. The 500 ms grace the picker used to hold it for kept the
//  quiz in `.recording`, where the speech-start window, VAD or the cap could
//  still end the recording first and open the voice sheet over the tapped
//  answer (RS-10 flake; the VM-level guard is in MCQSubmitInterruptTests).
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Picker wiring — hosted

private let testOptions = [
    (key: "a", value: "Mars"),
    (key: "b", value: "Jupiter"),
]

@Suite("MCQOptionPicker tap/voice race wiring (54.16)")
@MainActor
struct MCQOptionPickerRaceTests {
    @Test("a tap submits at once — no delayed hand-off")
    func tapSubmitsAtOnce() async throws {
        var selected: [String] = []
        let box = KeyBox()
        let binding = Binding<String?>(get: { box.key }, set: { box.key = $0 })
        let view = MCQOptionPicker(
            options: testOptions,
            onSelect: { key, _ in selected.append(key) },
            externalSelectedKey: binding
        )

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()
            #expect(selected == ["a"], "the tap must reach onSelect synchronously, once")
            #expect(box.key == "a")
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
    /// rewrites that key is what the screen shows (no divergence).
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
