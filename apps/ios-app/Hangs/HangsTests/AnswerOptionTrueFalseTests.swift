//
//  AnswerOptionTrueFalseTests.swift
//  HangsTests
//
//  Issue #45 task 45.10: True/False visual variant — 2-option MCQ renders at ~80pt
//  min height instead of the standard 64pt. Visual only, no model change.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("AnswerOption True/False Variant Tests")
@MainActor
struct AnswerOptionTrueFalseTests {
    // MARK: - AnswerOption minHeight parameter

    @Test("Default AnswerOption minHeight is 64pt (standard MCQ)")
    func defaultMinHeight() {
        let view = AnswerOption(key: "a", value: "Mars")
        #expect(view.minHeight == 64)
    }

    @Test("AnswerOption accepts minHeight override for T/F variant")
    func overrideMinHeight() {
        let view = AnswerOption(key: "a", value: "True", minHeight: 80)
        #expect(view.minHeight == 80)
    }

    // MARK: - MCQOptionPicker T/F height logic

    // (why: 2-option lists are T/F questions — taller rows aid readability while driving)

    @Test("MCQOptionPicker with 2 options uses 80pt optionMinHeight")
    func twoOptionPickerUsesTallHeight() {
        let picker = MCQOptionPicker(
            options: [(key: "a", value: "True"), (key: "b", value: "False")],
            onSelect: { _, _ in }
        )
        #expect(picker.optionMinHeight == 80)
    }

    @Test("MCQOptionPicker with 4 options uses 64pt optionMinHeight")
    func fourOptionPickerUsesStandardHeight() {
        let picker = MCQOptionPicker(
            options: [
                (key: "a", value: "Mars"),
                (key: "b", value: "Jupiter"),
                (key: "c", value: "Saturn"),
                (key: "d", value: "Neptune"),
            ],
            onSelect: { _, _ in }
        )
        #expect(picker.optionMinHeight == 64)
    }

    @Test("MCQOptionPicker with 3 options uses 64pt optionMinHeight (not T/F)")
    func threeOptionPickerUsesStandardHeight() {
        let picker = MCQOptionPicker(
            options: [
                (key: "a", value: "Alpha"),
                (key: "b", value: "Beta"),
                (key: "c", value: "Gamma"),
            ],
            onSelect: { _, _ in }
        )
        #expect(picker.optionMinHeight == 64)
    }
}
