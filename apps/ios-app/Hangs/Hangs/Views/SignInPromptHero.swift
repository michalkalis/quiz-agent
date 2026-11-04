//
//  SignInPromptHero.swift
//  Hangs
//
//  #217.4 (founder 2026-11-04, canvas F-Plus / F-Kredit / F-Balik): the
//  slightly tilted card at the top of the sign-in prompt that shows what was
//  just bought. Plus and credit are cobalt; a custom pack wears its own colour,
//  the same one as on Home and in My packs.
//

import SwiftUI

struct SignInPromptHero: View {
    @ScaledMetric(relativeTo: .title2) private var height: CGFloat = 84
    @ScaledMetric(relativeTo: .title2) private var wideWidth: CGFloat = 170

    let purchase: SignInPromptPurchase

    var body: some View {
        content
            .clipShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
            .rotationEffect(.degrees(Metrics.tilt))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("signInPrompt.hero")
    }

    @ViewBuilder private var content: some View {
        switch purchase {
        case .plus:
            card(style: cobalt, width: wideWidth) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.hangsHeading)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                Text(verbatim: "Trubbo Plus")
                    .font(Metrics.nameFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        case let .credit(questionCount):
            VStack(spacing: Theme.Hangs.Spacing.xxs / 2) {
                Text(verbatim: "+\(questionCount)")
                    .font(Metrics.countFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("questions")
                    .font(.hangsCaption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(Theme.Hangs.Spacing.xs)
            .foregroundStyle(cobalt.text)
            .frame(width: height, height: height)
            .background(cobalt.fill)
        case let .customPack(name, questionCount, colorKey):
            card(style: Theme.Hangs.Category.style(forPack: colorKey), width: wideWidth) {
                Spacer(minLength: 0)
                Text(verbatim: name)
                    .font(Metrics.nameFont)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text("\(questionCount) questions")
                    .font(.hangsCaption)
            }
        }
    }

    private var cobalt: Theme.Hangs.Category.Style {
        Theme.Hangs.Category.Style(fill: Theme.Hangs.Colors.accentPrimary, text: Theme.Hangs.Colors.textOnAccent)
    }

    private func card(
        style: Theme.Hangs.Category.Style,
        width: CGFloat,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs / 2) {
            content()
        }
        .padding(.horizontal, Theme.Hangs.Spacing.sm)
        .padding(.vertical, Theme.Hangs.Spacing.xs)
        .foregroundStyle(style.text)
        .frame(width: width, height: height, alignment: .leading)
        .background(style.fill)
    }

    private enum Metrics {
        static let radius: CGFloat = 20
        static let tilt: Double = -3
        static var nameFont: Font { Theme.Hangs.Fonts.content(20, weight: .bold) }
        static var countFont: Font { Theme.Hangs.Fonts.content(28, weight: .heavy) }
    }
}

#if DEBUG
    #Preview {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xl) {
            SignInPromptHero(purchase: .plus)
            SignInPromptHero(purchase: .credit(questionCount: 100))
            SignInPromptHero(purchase: .customPack(name: "Harry Potter", questionCount: 30, colorKey: "order-1"))
        }
        .padding()
        .background(Theme.Hangs.Colors.bgSheet)
    }
#endif
