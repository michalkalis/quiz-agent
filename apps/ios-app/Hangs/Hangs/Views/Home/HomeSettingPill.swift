//
//  HomeSettingPill.swift
//  Hangs
//
//  #194 C1 — one Home setting (quiz language, difficulty, categories) as a
//  glass pill: caption over the current value (canvas R-Home). The label of a
//  `Menu` or a `Button`; the control around it owns the identifier.
//

import SwiftUI

struct HomeSettingPill: View {
    let caption: LocalizedStringKey
    let value: String
    /// Categories may take two lines ("Všetky kategórie"); the others stay one.
    var valueLineLimit: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            Text(caption)
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(verbatim: value)
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .lineLimit(valueLineLimit)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Hangs.Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: Metrics.minHeight, maxHeight: .infinity)
        .contentShape(.rect)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cta, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        static let minHeight: CGFloat = 56
    }
}

#if DEBUG
    #Preview {
        HStack(spacing: 8) {
            HomeSettingPill(caption: "Quiz language", value: "Slovenčina")
            HomeSettingPill(caption: "Difficulty", value: "Medium")
            HomeSettingPill(caption: "Categories", value: "All Categories", valueLineLimit: 2)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
