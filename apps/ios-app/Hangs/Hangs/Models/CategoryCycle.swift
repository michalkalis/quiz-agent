//
//  CategoryCycle.swift
//  Hangs
//
//  #224.6 — the Home category deck steps through one category at a time:
//  All categories, then each category in `Config.categoryOptions` order, then
//  back to All. This is the pure stepping rule; the deck only draws it.
//

import Foundation

enum CategoryCycle {
    enum Direction: String, Equatable, Sendable {
        case next
        case previous
    }

    /// The cycle order: `nil` (all categories) first, then the taxonomy.
    static var order: [String?] {
        Config.categoryOptions.map(\.id)
    }

    /// Where a selection sits in the cycle. Empty = All (0); a multi-selection
    /// sits at its first-picked category (the one the player chose first);
    /// ids outside the taxonomy count as All.
    static func position(of selection: [String], in order: [String?] = CategoryCycle.order) -> Int {
        guard let first = selection.first else { return 0 }
        return order.firstIndex { $0 == first } ?? 0
    }

    /// The single-category selection one step away. From a multi-selection the
    /// step is taken from its first-picked category, so the first tap leaves
    /// the set for a neighbour of that category. Wraps in both directions.
    static func stepped(
        from selection: [String],
        _ direction: Direction,
        in order: [String?] = CategoryCycle.order
    ) -> [String] {
        guard !order.isEmpty else { return [] }
        let delta = direction == .next ? 1 : -1
        let index = (position(of: selection, in: order) + delta + order.count) % order.count
        return order[index].map { [$0] } ?? []
    }
}
