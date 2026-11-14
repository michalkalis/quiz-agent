//
//  SharedQuizSendCard.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 1A): a quiet card under the round's
//  score: "Send to a friend", what the friend gets, a chevron. The tap makes
//  the link, then opens the share sheet; the card spins meanwhile.
//

import SwiftUI

struct SharedQuizSendCard: View {
    private enum Metrics {
        /// Canvas 1A: the round icon plate.
        static let iconPlate: CGFloat = 40
        static let icon: CGFloat = 18
        static let chevron: CGFloat = 13
    }

    let isCreating: Bool
    let failureMessage: String?
    let action: () -> Void

    var body: some View {
        // a11y-id: call-site
        Button(action: action) {
            HangsCard(padding: EdgeInsets(
                top: Theme.Hangs.Spacing.sm, leading: Theme.Hangs.Spacing.md,
                bottom: Theme.Hangs.Spacing.sm, trailing: Theme.Hangs.Spacing.md
            )) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.hangsBody(Metrics.icon, weight: .semibold))
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .frame(width: Metrics.iconPlate, height: Metrics.iconPlate)
                        .background(Circle().fill(Theme.Hangs.Colors.bgInset))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs / 2) {
                        Text("Send to a friend")
                            .font(.hangsLabel)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                        detail
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isCreating {
                        ProgressView()
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.hangsBody(Metrics.chevron, weight: .semibold))
                            .foregroundStyle(Theme.Hangs.Colors.mutedFaint)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isCreating)
    }

    @ViewBuilder private var detail: some View {
        if let failureMessage {
            Text(verbatim: failureMessage)
        } else {
            Text("They play the same questions and you compare.")
        }
    }
}
