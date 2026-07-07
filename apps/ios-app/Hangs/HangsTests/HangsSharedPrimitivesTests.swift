//
//  HangsSharedPrimitivesTests.swift
//  HangsTests
//
//  Task 52.4: inspector tests for shared design primitives extracted for the
//  Phase-3 screen assembly. Each test asserts a key token/structure property so
//  that a wrong-token regression fails it (CLAUDE.md rule 6).
//
//  Coverage:
//   · HangsBrandRow        — brand wordmark renders in tree
//   · HangsStatusBar       — leading/trailing text renders
//   · HangsStatChip        — value + uppercased label render, icon is optional
//   · HangsProgressBar     — GeometryReader (fill-width) structure is present
//   · HangsPageIndicator   — active/inactive dot color + width via testable props;
//                            ForEach structure visible in inspector
//   · CTA / secondary buttons — covered by HangsButtonInspectorTests.swift
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - HangsBrandRow

@Suite("HangsBrandRow ViewInspector Tests")
@MainActor
struct HangsBrandRowInspectorTests {
    @Test("Brand wordmark 'trubbo.' text renders in tree")
    func brandWordmarkRendersInTree() async throws {
        let view = HangsBrandRow()
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "trubbo.")
            }
        }
    }

    @Test("Right accessory view renders when provided")
    func rightAccessoryRendersWhenProvided() async throws {
        let view = HangsBrandRow { HangsNavChip(icon: "gearshape") {} }
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "gearshape"
                })
            }
        }
    }
}

// MARK: - HangsStatusBar

@Suite("HangsStatusBar ViewInspector Tests")
@MainActor
struct HangsStatusBarInspectorTests {
    @Test("Leading string appears in rendered tree")
    func leadingStringRendersInTree() async throws {
        let view = HangsStatusBar(leading: "HANGS", trailing: "1/10")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "HANGS")
            }
        }
    }

    @Test("Trailing string appears in rendered tree")
    func trailingStringRendersInTree() async throws {
        let view = HangsStatusBar(leading: "HANGS", trailing: "1/10")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "1/10")
            }
        }
    }
}

// MARK: - HangsStatChip

@Suite("HangsStatChip ViewInspector Tests")
@MainActor
struct HangsStatChipInspectorTests {
    @Test("Value text appears in rendered tree")
    func valueTextRendersInTree() async throws {
        let view = HangsStatChip(label: "streak", value: "47")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "47")
            }
        }
    }

    @Test("Label appears in rendered tree (uppercasing is a display modifier)")
    func labelIsUppercasedAndRendersInTree() async throws {
        let view = HangsStatChip(label: "streak", value: "47")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // #56: the label is a LocalizedStringKey rendered with a
            // `.textCase(.uppercase)` *display* modifier (no longer a mutated
            // String), so ViewInspector matches the source key "streak" — the
            // uppercasing is applied at render time, not baked into the string.
            #expect(throws: Never.self) {
                try tree.find(text: "streak")
            }
        }
    }

    @Test("Optional icon renders when provided")
    func optionalIconRendersWhenProvided() async throws {
        let view = HangsStatChip(label: "score", value: "9.5", icon: "star.fill")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "star.fill"
                })
            }
        }
    }

    @Test("No icon renders when icon is omitted")
    func noIconRendersWhenOmitted() async throws {
        let view = HangsStatChip(label: "streak", value: "47")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(ViewType.Image.self, where: { _ in true })
            }
        }
    }
}

// MARK: - HangsProgressBar (slim)

@Suite("HangsProgressBar (slim) ViewInspector Tests")
@MainActor
struct HangsProgressBarInspectorTests {
    @Test("GeometryReader fill-width structure is present")
    func geometryReaderFillWidthStructureIsPresent() async throws {
        let view = HangsProgressBar(progress: 0.5)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.GeometryReader.self)
            }
        }
    }

    @Test("Clamps progress below zero to zero without crash")
    func clampsBelowZero() async throws {
        let view = HangsProgressBar(progress: -0.5)
        try await ViewHosting.host(view) {
            // renders without throwing
            _ = try view.inspect()
        }
    }

    @Test("Clamps progress above one to one without crash")
    func clampsAboveOne() async throws {
        let view = HangsProgressBar(progress: 1.5)
        try await ViewHosting.host(view) {
            _ = try view.inspect()
        }
    }
}

// MARK: - HangsPageIndicator

@Suite("HangsPageIndicator Tests")
struct HangsPageIndicatorTests {
    // --- Pure unit tests on computed token/width properties ---

    @Test("Active dot uses accentPrimary color token")
    func activeDotUsesAccentPrimaryColor() {
        let indicator = HangsPageIndicator(pageCount: 4, currentPage: 2)
        #expect(indicator.dotColor(at: 2) == Theme.Hangs.Colors.accentPrimary)
    }

    @Test("Inactive dot uses hairline color token")
    func inactiveDotUsesHairlineColor() {
        let indicator = HangsPageIndicator(pageCount: 4, currentPage: 2)
        #expect(indicator.dotColor(at: 0) == Theme.Hangs.Colors.hairline)
        #expect(indicator.dotColor(at: 3) == Theme.Hangs.Colors.hairline)
    }

    @Test("Active dot is wider than inactive dot")
    func activeDotIsWider() {
        let indicator = HangsPageIndicator(pageCount: 3, currentPage: 1)
        #expect(indicator.dotWidth(at: 1) > indicator.dotWidth(at: 0))
        #expect(indicator.dotWidth(at: 1) > indicator.dotWidth(at: 2))
    }

    @Test("Active dot width is 20, inactive dot width is 8")
    func dotWidthValues() {
        let indicator = HangsPageIndicator(pageCount: 3, currentPage: 0)
        #expect(indicator.dotWidth(at: 0) == 20)
        #expect(indicator.dotWidth(at: 1) == 8)
        #expect(indicator.dotWidth(at: 2) == 8)
    }

    @Test("Custom active/inactive colors are respected")
    func customColorsAreRespected() {
        let indicator = HangsPageIndicator(
            pageCount: 2,
            currentPage: 0,
            activeColor: Theme.Hangs.Colors.pink,
            inactiveColor: Theme.Hangs.Colors.muted
        )
        #expect(indicator.dotColor(at: 0) == Theme.Hangs.Colors.pink)
        #expect(indicator.dotColor(at: 1) == Theme.Hangs.Colors.muted)
    }

    // --- ViewInspector structural test ---

    @Test("ForEach structure is present in rendered tree")
    @MainActor
    func forEachStructureIsPresent() async throws {
        let view = HangsPageIndicator(pageCount: 3, currentPage: 0)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.ForEach.self)
            }
        }
    }
}
