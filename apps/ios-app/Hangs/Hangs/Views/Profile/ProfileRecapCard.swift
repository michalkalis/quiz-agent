//
//  ProfileRecapCard.swift
//  Hangs
//
//  #216.3 (founder 2026-10-30, S1): the newest recap as one card on the
//  Profile — its title ("Your October"), three numbers (questions in total,
//  strong suit, when you play) and Share, which sends the same card as a
//  story-size picture. Replaces the banner and the story of #213.5.
//

import SwiftUI

struct ProfileRecapCard: View {
    @Environment(\.locale) private var locale
    @State private var shareImage: Image?
    let recap: PlayerRecap
    let rows: [StatCard]
    let onShareOpened: () -> Void

    private let style = Theme.Hangs.Recap.cards[0]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            RecapCopy.title(recap, locale: locale)
                .font(.hangsHeading)
                .textCase(.uppercase)
                .hangsHeadlineFit()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                ForEach(rows, id: \.kind) { card in
                    RecapNumberRow(card: card, valueFont: .hangsLabel)
                }
            }
            shareButton
        }
        .padding(Theme.Hangs.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(style.text)
        .background(RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous).fill(style.fill))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.recap")
        .task(id: recap.id) { shareImage = renderShareImage() }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let shareImage {
            ShareLink(item: shareImage, preview: SharePreview(RecapCopy.title(recap, locale: locale), image: shareImage)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.hangsButton)
                    .foregroundStyle(style.fill)
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .frame(minHeight: Metrics.shareHeight)
                    .background(Capsule().fill(style.text))
            }
            .simultaneousGesture(TapGesture().onEnded(onShareOpened))
            .accessibilityIdentifier("recap.share")
        }
    }

    /// The card at story size, 1080×1920 pixels.
    private func renderShareImage() -> Image? {
        let picture = RecapShareImage(recap: recap, rows: rows, style: style)
            .frame(width: Metrics.shareSize.width, height: Metrics.shareSize.height)
            .environment(\.locale, locale)
            .environment(\.dynamicTypeSize, .large)
        let renderer = ImageRenderer(content: picture)
        renderer.scale = Metrics.shareScale
        return renderer.uiImage.map { Image(uiImage: $0) }
    }

    private enum Metrics {
        static let shareHeight: CGFloat = 44
        static let shareSize = CGSize(width: 360, height: 640)
        static let shareScale: CGFloat = 3
    }
}
