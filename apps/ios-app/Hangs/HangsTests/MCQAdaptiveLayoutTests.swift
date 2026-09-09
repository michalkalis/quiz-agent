//
//  MCQAdaptiveLayoutTests.swift
//  HangsTests
//
//  #174 C2 (founder, 2026-09-08): the 2×2 grid gives each option ~150pt of
//  width. Slovak options run 6–10 words, so real questions shrank and
//  ellipsised — a truncated answer is unanswerable. The grid is now conditional
//  on every option fitting; anything longer falls back to full-width rows.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

private let shortOptions = [
    (key: "a", value: "Star City"),
    (key: "b", value: "Gotham"),
    (key: "c", value: "Metropolis"),
    (key: "d", value: "Central City"),
]

private let longOptions = [
    (key: "a", value: "Vlasy narastú asi o 1,25 cm za mesiac"),
    (key: "b", value: "Nechty na rukách rastú štyrikrát rýchlejšie ako na nohách"),
    (key: "c", value: "Deti rastú rýchlejšie na jar"),
    (key: "d", value: "Nechty na nohách rastú štyrikrát rýchlejšie ako na rukách"),
]

@MainActor
@Suite("MCQ adaptive option layout — grid vs. list (#174 C2)")
struct MCQAdaptiveLayoutTests {
    private func picker(
        _ options: [(key: String, value: String)],
        onSelect: @escaping (String, String) -> Void = { _, _ in }
    ) -> MCQOptionPicker {
        MCQOptionPicker(options: options, onSelect: onSelect)
    }

    /// The rule, both directions: short options keep the playful grid, and ONE
    /// long option is enough to drop the whole set into rows — a mixed set in a
    /// grid still truncates the long one, which is the failure being fixed.
    @Test("every option short ⇒ grid; any option long ⇒ list")
    func layoutFollowsOptionLength() {
        #expect(picker(shortOptions).usesGrid)
        #expect(picker(longOptions).usesGrid == false)

        var mixed = shortOptions
        mixed[2] = (key: "c", value: longOptions[1].value)
        #expect(picker(mixed).usesGrid == false, "one long option must move the whole set to rows")
    }

    /// The threshold is a real boundary, not a vibe: at the limit the tile still
    /// holds the text, one character past it the row takes over. Pinned so a
    /// silent retune of the constant has to be deliberate.
    @Test("the grid threshold holds at exactly the maximum option length")
    func thresholdBoundary() {
        let limit = MCQOptionPicker.gridMaxOptionLength
        let atLimit = String(repeating: "a", count: limit)
        let overLimit = String(repeating: "a", count: limit + 1)

        #expect(picker([
            (key: "a", value: atLimit),
            (key: "b", value: atLimit),
            (key: "c", value: atLimit),
            (key: "d", value: atLimit),
        ]).usesGrid)
        #expect(picker([
            (key: "a", value: atLimit),
            (key: "b", value: overLimit),
            (key: "c", value: atLimit),
            (key: "d", value: atLimit),
        ]).usesGrid == false)
    }

    /// The structural half of the same rule: the grid path is a `LazyVGrid`, the
    /// row path is not. Asserting the container (not just the flag) is what
    /// catches a `body` that computes `usesGrid` and then ignores it.
    @Test("the chosen flag actually renders the chosen container")
    func flagDrivesTheRenderedContainer() async throws {
        let short = picker(shortOptions)
        try await ViewHosting.host(short) {
            #expect(throws: Never.self) { try short.inspect().find(ViewType.LazyVGrid.self) }
        }

        let long = picker(longOptions)
        try await ViewHosting.host(long) {
            #expect(throws: (any Error).self, "long options must not render in the 2×2 grid") {
                try long.inspect().find(ViewType.LazyVGrid.self)
            }
            // …and all four options are still on screen, in the row layout.
            for option in longOptions {
                #expect(throws: Never.self, "option \(option.key) went missing in the list layout") {
                    try long.inspect().find(viewWithAccessibilityIdentifier: "mcq.option.\(option.key)")
                }
            }
        }
    }

    /// Tap-to-submit is the primary way an MCQ is answered; the new layout is a
    /// second render path for it, so it gets the same guarantee the grid has —
    /// one tap, one submit, with the tapped option's own key and value.
    @Test("tap-to-submit still fires exactly once in the list layout")
    func tapSubmitsOnceInListLayout() async throws {
        var selected: (key: String, value: String)?
        var count = 0
        let view = picker(longOptions) { key, value in
            selected = (key, value)
            count += 1
        }

        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()

            // Poll up to ~3s — the 500ms delayed submit can overshoot a fixed
            // wait under load (same pattern as MCQOptionPickerRaceTests).
            for _ in 0 ..< 150 where selected == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            #expect(selected?.key == "a")
            #expect(selected?.value == longOptions[0].value)
            #expect(count == 1)
        }
    }
}
