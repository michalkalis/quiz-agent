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

    @Test("Default state: subtle border, soft-purple badge (accentPrimarySoft token), purple letter")
    func defaultStateColors() {
        let view = AnswerOption(key: "a", value: "Mars", state: .default)
        #expect(view.borderColor == Theme.Hangs.Colors.subtleBorder)
        #expect(view.badgeFill == Theme.Hangs.Colors.accentPrimarySoft)
        #expect(view.letterColor == Theme.Hangs.Colors.accentPrimary)
        #expect(view.statusSymbol == nil)
        #expect(view.statusIconColor == nil)
    }

    @Test("Selected state: purple border + solid purple badge + white letter, no status badge")
    func selectedStateColors() {
        let view = AnswerOption(key: "b", value: "Jupiter", state: .selected)
        #expect(view.borderColor == Theme.Hangs.Colors.accentPrimary)
        #expect(view.badgeFill == Theme.Hangs.Colors.accentPrimary)
        #expect(view.letterColor == .white)
        #expect(view.statusSymbol == nil)
        #expect(view.statusIconColor == nil)
    }

    @Test("Correct state: green border + badge + checkmark circle (white icon on green fill)")
    func correctStateColors() {
        let view = AnswerOption(key: "c", value: "Saturn", state: .correct)
        #expect(view.borderColor == Theme.Hangs.Colors.greenCheck)
        #expect(view.badgeFill == Theme.Hangs.Colors.greenCheck)
        #expect(view.letterColor == .white)
        #expect(view.statusSymbol == "checkmark")
        #expect(view.statusIconColor == .white)
    }

    @Test("Incorrect state: pink border + badge + xmark circle (white icon on pink fill)")
    func incorrectStateColors() {
        let view = AnswerOption(key: "d", value: "Neptune", state: .incorrect)
        #expect(view.borderColor == Theme.Hangs.Colors.pink)
        #expect(view.badgeFill == Theme.Hangs.Colors.pink)
        #expect(view.letterColor == .white)
        #expect(view.statusSymbol == "xmark")
        #expect(view.statusIconColor == .white)
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

// MARK: - AnswerTile (2×2 grid, #125 Variant A)

/// The half-width grid tile must read the SAME state→color roles as the full-
/// width row (no second copy) and keep the `mcq.option.<key>` id the page
/// objects / voice-match highlight depend on.
@Suite("AnswerTile Inspector Tests (#125)")
@MainActor
struct AnswerTileInspectorTests {
    /// The shared `AnswerOption.State` mapping — both `AnswerOption` and
    /// `AnswerTile` render from these exact roles, so asserting it once covers
    /// the tile's colours too.
    @Test("Shared state → color mapping (single source of truth)")
    func sharedStateMapping() {
        #expect(AnswerOption.State.default.borderColor == Theme.Hangs.Colors.subtleBorder)
        #expect(AnswerOption.State.default.badgeFill == Theme.Hangs.Colors.accentPrimarySoft)
        #expect(AnswerOption.State.default.letterColor == Theme.Hangs.Colors.accentPrimary)
        #expect(AnswerOption.State.default.statusSymbol == nil)

        #expect(AnswerOption.State.selected.borderColor == Theme.Hangs.Colors.accentPrimary)
        #expect(AnswerOption.State.selected.badgeFill == Theme.Hangs.Colors.accentPrimary)
        #expect(AnswerOption.State.selected.letterColor == .white)

        #expect(AnswerOption.State.correct.borderColor == Theme.Hangs.Colors.greenCheck)
        #expect(AnswerOption.State.correct.statusSymbol == "checkmark")

        #expect(AnswerOption.State.incorrect.borderColor == Theme.Hangs.Colors.pink)
        #expect(AnswerOption.State.incorrect.statusSymbol == "xmark")
    }

    @Test("Tile renders the uppercased letter badge")
    func letterAppearsInTree() async throws {
        let view = AnswerTile(key: "a", value: "Mars")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "A")
            }
        }
    }

    @Test("Tile renders the answer value")
    func valueAppearsInTree() async throws {
        let view = AnswerTile(key: "b", value: "Jupiter")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Jupiter")
            }
        }
    }

    @Test("Tile keeps the mcq.option.<key> a11y id")
    func accessibilityIdentifierPresent() async throws {
        let view = AnswerTile(key: "c", value: "Saturn")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "mcq.option.c")
            }
        }
    }

    @Test("Tapping the tile fires its action")
    func tapFiresAction() async throws {
        var tapped = false
        let view = AnswerTile(key: "a", value: "Mars", action: { tapped = true })
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()
            #expect(tapped == true)
        }
    }
}
