//
//  AnswerOptionInspectorTests.swift
//  HangsTests
//
//  Issue #45 task 45.4: assertions for the 4-state AnswerOption component.
//  Colors are verified via the internal state→style mapping (the intent: which
//  state maps to which token); structure (letter, status symbol, a11y id) is
//  verified in the rendered tree via ViewInspector. vzor: HangsButtonInspectorTests.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("AnswerOption Inspector Tests")
@MainActor
struct AnswerOptionInspectorTests {
    // MARK: - State → color mapping (why: each state must read as its design role)

    @Test("Default state: subtle border, soft-purple badge, purple letter")
    func defaultStateColors() {
        let view = AnswerOption(key: "a", value: "Mars", state: .default)
        #expect(view.borderColor == Theme.Hangs.Colors.subtleBorder)
        #expect(view.badgeFill == AnswerOption.softBadge)
        #expect(view.letterColor == Theme.Hangs.Colors.accentPrimary)
        #expect(view.statusSymbol == nil)
    }

    @Test("Selected state: purple border + solid purple badge + white letter")
    func selectedStateColors() {
        let view = AnswerOption(key: "b", value: "Jupiter", state: .selected)
        #expect(view.borderColor == Theme.Hangs.Colors.accentPrimary)
        #expect(view.badgeFill == Theme.Hangs.Colors.accentPrimary)
        #expect(view.letterColor == .white)
        #expect(view.statusSymbol == nil)
    }

    @Test("Correct state: green border + badge + checkmark")
    func correctStateColors() {
        let view = AnswerOption(key: "c", value: "Saturn", state: .correct)
        #expect(view.borderColor == Theme.Hangs.Colors.greenCheck)
        #expect(view.badgeFill == Theme.Hangs.Colors.greenCheck)
        #expect(view.letterColor == .white)
        #expect(view.statusSymbol == "checkmark")
    }

    @Test("Incorrect state: pink border + badge + xmark")
    func incorrectStateColors() {
        let view = AnswerOption(key: "d", value: "Neptune", state: .incorrect)
        #expect(view.borderColor == Theme.Hangs.Colors.pink)
        #expect(view.badgeFill == Theme.Hangs.Colors.pink)
        #expect(view.letterColor == .white)
        #expect(view.statusSymbol == "xmark")
    }

    // MARK: - Rendered structure (ViewInspector)

    @Test("Letter badge renders the uppercased key")
    func letterAppearsInTree() async throws {
        let view = AnswerOption(key: "a", value: "Mars")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "A")
            }
        }
    }

    @Test("Correct state renders a checkmark SF Symbol")
    func correctRendersCheckmark() async throws {
        let view = AnswerOption(key: "c", value: "Saturn", state: .correct)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "checkmark"
                })
            }
        }
    }

    @Test("Incorrect state renders an xmark SF Symbol")
    func incorrectRendersXmark() async throws {
        let view = AnswerOption(key: "d", value: "Neptune", state: .incorrect)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "xmark"
                })
            }
        }
    }

    @Test("Default state renders no status SF Symbol")
    func defaultRendersNoStatusSymbol() async throws {
        let view = AnswerOption(key: "a", value: "Mars", state: .default)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(ViewType.Image.self, where: { _ in true })
            }
        }
    }

    @Test("Accessibility identifier mcq.option.<key> is present")
    func accessibilityIdentifierPresent() async throws {
        let view = AnswerOption(key: "b", value: "Jupiter")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "mcq.option.b")
            }
        }
    }
}
