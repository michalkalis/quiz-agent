//
//  ProfileRecapBanner.swift
//  Hangs
//
//  #213.5 (canvas "Lišta a Profil", Profil 1): the newest recap on top of the
//  Profile — "New recap / Your October" on cobalt with a play button. Opens
//  the story.
//

import SwiftUI

struct ProfileRecapBanner: View {
    @Environment(\.locale) private var locale
    let recap: PlayerRecap
    let action: () -> Void

    private let style = Theme.Hangs.Recap.cards[0]

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text(recap.seen ? "Your recap" : "New recap")
                        .font(.hangsOverline)
                        .textCase(.uppercase)
                        .opacity(Metrics.kickerOpacity)
                    RecapCopy.title(recap, locale: locale)
                        .font(.hangsHeading)
                        .textCase(.uppercase)
                        .hangsHeadlineFit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.fill")
                    .font(.hangsLabel)
                    .foregroundStyle(style.fill)
                    .frame(width: Metrics.play, height: Metrics.play)
                    .background(Circle().fill(style.text))
                    .accessibilityHidden(true)
            }
            .padding(Theme.Hangs.Spacing.md)
            .foregroundStyle(style.text)
            .background(RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous).fill(style.fill))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("profile.recap")
    }

    private enum Metrics {
        static let kickerOpacity = 0.8
        static let play: CGFloat = 44
    }
}
