//
//  HomePlanHeadLine.swift
//  Hangs
//
//  The plan card's first line: the plan's name or number, its status pill and
//  its link. One line while it fits; otherwise the pill and link drop under
//  it, and at the largest text sizes each takes its own line. The pill and
//  link never shrink, so a one-line layout that didn't fit pushed the whole
//  card past the screen edge (sk/cs "renewal failed" even at default size) or
//  squeezed the free caption into one syllable per line.
//
//  `ViewThatFits` measures each layout's ideal width, so the switch follows
//  the real translation and text size instead of a fixed type-size threshold
//  (the same approach as `HangsLabelValueLine`).
//

import SwiftUI

struct HomePlanHeadLine<Lead: View, Pill: View, Link: View>: View {
    @ViewBuilder let lead: Lead
    @ViewBuilder let pill: Pill
    @ViewBuilder let link: Link

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                // First claim on the width, so a flexible lead (the free
                // caption) fills the line instead of splitting it with the
                // spacer; a plain name just keeps its own width.
                lead.layoutPriority(1)
                pill
                Spacer(minLength: 0)
                link
            }
            VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
                lead
                HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                    pill
                    Spacer(minLength: 0)
                    link
                }
            }
            VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
                lead
                pill
                link
            }
        }
    }
}
