//
//  ExtraCategoryBadge.swift
//  Hangs
//
//  #242 — the small label of a free rotating category: "new", and "until <date>"
//  when the server announced an end. Drawn on the deck card and the picker tile.
//

import SwiftUI

struct ExtraCategoryBadge: View {
    @Environment(\.locale) private var locale

    let category: ExtraCategory

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            Text("new")
                .textCase(.uppercase)
                .font(.hangsOverline)
            if let until = category.untilLabel(locale: locale) {
                Text("until \(until)")
                    .font(.hangsCaption)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.extraBadge.\(category.key)")
    }
}
