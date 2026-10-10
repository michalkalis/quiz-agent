//
//  DeckIdentityTests.swift
//  HangsTests
//
//  #198 — the redesign shipped black question cards with a raw "ADULTS" chip:
//  any category outside the taxonomy fell through to ink and printed its id.
//  These pin what a card shows for a question: a known category's colour and
//  name, a custom pack's own stable colour, and never ink or a raw id.
//

import SwiftUI
import Testing
import UIKit
@testable import Hangs

@MainActor
struct DeckIdentityTests {
    private func resolved(_ color: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    private func sameFill(_ lhs: Theme.Hangs.Category.Style, _ rhs: Theme.Hangs.Category.Style) -> Bool {
        [UIUserInterfaceStyle.light, .dark].allSatisfy { resolved(lhs.fill, $0) == resolved(rhs.fill, $0) }
    }

    @Test("An unknown category is cobalt with no chip — never a black card or a raw id")
    func unknownCategoryFallsBackToCobaltWithoutChip() {
        for raw in ["general", "adults", "kids", ""] {
            let identity = DeckIdentity(category: raw, packId: nil)
            #expect(identity.chipName == nil, "raw id \(raw) must not reach the chip")
            #expect(sameFill(identity.style, Theme.Hangs.Category.style(for: "geography-world")))
            let ink = UIColor(Color(hex: "#111216"))
            #expect(resolved(identity.style.fill, .light) != ink.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
        }
    }

    @Test("A taxonomy category shows its own colour and localized name")
    func taxonomyCategoryKeepsItsColourAndName() {
        let identity = DeckIdentity(category: "history", packId: nil)
        #expect(identity.chipName == Config.categoryDisplayName(for: "history"))
        #expect(sameFill(identity.style, Theme.Hangs.Category.style(for: "history")))
    }

    @Test("A custom pack's card says Custom pack and wears the pack's colour, whatever its category")
    func customPackUsesPackColour() {
        let packId = "22222222-2222-2222-2222-222222222222"
        let identity = DeckIdentity(category: "history", packId: packId)
        #expect(identity.chipName == String(localized: "Custom pack"))
        #expect(sameFill(identity.style, Theme.Hangs.Category.style(forPack: packId)))
    }

    /// The pack colour is a hash of its id. `hashValue` would reseed every
    /// launch; a changed hash would repaint every pack the player already
    /// knows by colour — so the mapping is pinned to fixed values.
    @Test("A pack's colour is stable across launches and releases")
    func packColourIsPinned() {
        let count = Theme.Hangs.Category.taxonomy.count
        #expect(Theme.Hangs.Category.stableIndex(of: "22222222-2222-2222-2222-222222222222", count: count) == 2)
        #expect(Theme.Hangs.Category.stableIndex(of: "88888888-8888-8888-8888-888888888888", count: count) == 1)
        #expect(Theme.Hangs.Category.stableIndex(of: "66666666-6666-6666-6666-666666666666", count: count) == 3)
    }

    @Test("Different packs spread over the palette instead of sharing one colour")
    func packsSpreadOverPalette() {
        let count = Theme.Hangs.Category.taxonomy.count
        let ids = (0 ..< 50).map { "pack-\($0)" }
        let used = Set(ids.map { Theme.Hangs.Category.stableIndex(of: $0, count: count) })
        #expect(used.count == count)
    }
}
