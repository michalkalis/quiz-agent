//
//  OnboardingView.swift
//  Hangs
//
//  Onboarding flow bound to OnboardingViewModel (52.5 state machine).
//  Pages: Welcome (gkeCn) · Features (hTdkE) · Mic Access (haWJM) · Denied (COHnz).
//  #52 task 52.13. #194 C7: "Sklo nad kartami" restyle (canvas Bg-Onboarding,
//  Bg-Features, Bg-Mic, Bg-MicDenied).
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            // #188 G9: at large Dynamic Type a page can outgrow the screen and
            // push Continue off it. The page keeps its centred layout while it
            // fits and scrolls above the pinned controls once it doesn't.
            ViewThatFits(in: .vertical) {
                page
                ScrollView { page }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxHeight: .infinity)

            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: viewModel.page)
        .accessibilityIdentifier("onboarding.root")
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        switch viewModel.page {
        case .welcome: welcomePage
        case .features: featuresPage
        case .permission: permissionPage
        case .permissionDenied: deniedPage
        }
    }

    // #194 C7: each page is one category-colour card with the page's glyph
    // (canvas Bg-Onboarding / Bg-Mic / Bg-MicDenied), then a left-aligned
    // title and text. Static: the illustration does not loop.
    private var welcomePage: some View {
        illustratedPage(
            title: "ANSWER BY VOICE",
            text: "Trubbo reads questions aloud and listens for your answers. No tapping needed during a quiz."
        ) {
            illustrationCard(categoryId: "geography-world") { style in
                VStack(spacing: Theme.Hangs.Spacing.xl) {
                    glyphDisc(systemName: "mic.fill", glyph: style.text, disc: style.text.opacity(0.18))
                    soundBars(color: style.text)
                }
            }
        }
        .accessibilityIdentifier("onboarding.welcome")
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.lg) {
            textBlock(title: "HANDS-FREE", text: "Perfect for driving, cooking, or walking.")
                .padding(.top, Theme.Hangs.Spacing.md)

            featuresCard

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .accessibilityIdentifier("onboarding.features")
    }

    private var permissionPage: some View {
        illustratedPage(
            title: "MIC ACCESS",
            text: "Trubbo needs microphone access to hear your voice answers. You can also type answers as a fallback."
        ) {
            illustrationCard(categoryId: "movies-music") { style in
                glyphDisc(systemName: "mic.fill", glyph: style.fill, disc: Theme.Hangs.Category.chipFill)
            }
        }
        .accessibilityIdentifier("onboarding.permission")
    }

    private var deniedPage: some View {
        illustratedPage(
            title: "MIC IS OFF",
            text: "Voice answers need the mic. Turn it on in Settings, or keep playing by typing your answers."
        ) {
            illustrationCard(categoryId: "sports") { style in
                glyphDisc(systemName: "mic.slash.fill", glyph: style.fill, disc: style.text)
            }
        }
        .accessibilityIdentifier("onboarding.denied")
    }

    // MARK: - Shared helpers

    private func illustratedPage(
        title: LocalizedStringKey,
        text: LocalizedStringKey,
        @ViewBuilder illustration: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: Theme.Hangs.Spacing.md)
            illustration()
                .frame(maxWidth: .infinity)
            Spacer(minLength: Theme.Hangs.Spacing.xl)
            textBlock(title: title, text: text)
                .padding(.horizontal, Theme.Hangs.Spacing.sm)
            Spacer(minLength: Theme.Hangs.Spacing.md)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
    }

    private func illustrationCard(
        categoryId: String,
        @ViewBuilder content: (Theme.Hangs.Category.Style) -> some View
    ) -> some View {
        let style = Theme.Hangs.Category.style(for: categoryId)
        return content(style)
            .frame(maxWidth: Metrics.cardSize.width)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.cardSize.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                    .fill(style.fill)
                    .frame(maxWidth: Metrics.cardSize.width)
                    .hangsShadow(Theme.Hangs.Shadow.raised)
            )
            .accessibilityHidden(true)
    }

    private func glyphDisc(systemName: String, glyph: Color, disc: Color) -> some View {
        Image(systemName: systemName)
            .font(.hangsDisplaySM)
            .foregroundStyle(glyph)
            .frame(width: Metrics.disc, height: Metrics.disc)
            .background(Circle().fill(disc))
    }

    /// Five static bars: the "it listens" mark under the welcome mic.
    private func soundBars(color: Color) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            ForEach(Metrics.bars.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: Metrics.barWidth, height: Metrics.bars[index])
            }
        }
    }

    private func textBlock(title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            Text(title)
                .font(.hangsDisplaySM)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.hangsBodyLG)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Features card

    /// #194 C7 (canvas Bg-Features): the four command tips as cards in
    /// category colours, the last one plain — the buttons that always work.
    private var featuresCard: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            ForEach(OnboardingFeature.all.indices, id: \.self) { index in
                featureRow(OnboardingFeature.all[index])
            }
        }
    }

    private func featureRow(_ feature: OnboardingFeature) -> some View {
        let style = feature.categoryId.map { Theme.Hangs.Category.style(for: $0) }
        let text = style?.text ?? Theme.Hangs.Colors.ink
        return HStack(alignment: .top, spacing: Theme.Hangs.Spacing.sm) {
            Image(systemName: feature.icon)
                .font(.hangsLabel)
                .frame(width: Metrics.featureIcon, height: Metrics.featureIcon)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.chip, style: .continuous)
                        .fill(text.opacity(0.14))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                Text(feature.title)
                    .font(.hangsLabel)
                Text(feature.description)
                    .font(.hangsBody)
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(text)
        .padding(Theme.Hangs.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(style?.fill ?? Theme.Hangs.Colors.bgCard)
                .strokeBorder(style == nil ? Theme.Hangs.Colors.hairline : Color.clear)
        )
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        /// Canvas illustration card (294 × 276) and the glyph disc on it.
        static let cardSize = CGSize(width: 294, height: 276)
        static let disc: CGFloat = 120
        static let barWidth: CGFloat = 5
        static let bars: [CGFloat] = [12, 22, 30, 22, 12]
        static let featureIcon: CGFloat = 40
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            HangsPageIndicator(
                pageCount: viewModel.pageCount,
                currentPage: viewModel.pageIndex,
                activeColor: viewModel.page == .permissionDenied
                    ? Theme.Hangs.Colors.warning
                    : Theme.Hangs.Colors.ink,
                inactiveColor: Theme.Hangs.Colors.track
            )
            .accessibilityIdentifier("onboarding.pageIndicator")

            primaryButton

            secondaryButton
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.sm)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.page {
        case .welcome, .features:
            HangsPrimaryButton(title: "Continue", icon: "arrow.right") {
                viewModel.advance()
            }
            .accessibilityIdentifier("onboarding.continue")

        case .permission:
            HangsPrimaryButton(title: "Allow Microphone", icon: "mic.fill") {
                Task { await viewModel.requestMicPermission() }
            }
            .accessibilityIdentifier("onboarding.allowMic")

        case .permissionDenied:
            HangsPrimaryButton(title: "Open Settings", icon: "gearshape.fill") {
                if let url = URL(string: "app-settings:") {
                    openURL(url)
                }
            }
            .accessibilityIdentifier("onboarding.openSettings")
        }
    }

    @ViewBuilder
    private var secondaryButton: some View {
        switch viewModel.page {
        case .welcome, .features:
            HangsSecondaryButton(title: "Skip") {
                viewModel.continueWithoutMic()
            }
            .accessibilityIdentifier("onboarding.skip")

        case .permission:
            HangsSecondaryButton(title: "Maybe later") {
                viewModel.continueWithoutMic()
            }
            .accessibilityIdentifier("onboarding.maybeLater")

        case .permissionDenied:
            HangsSecondaryButton(title: "Type answers instead", icon: "keyboard") {
                viewModel.continueWithoutMic()
            }
            .accessibilityIdentifier("onboarding.typeInstead")
        }
    }
}

// MARK: - Feature data

private struct OnboardingFeature {
    let icon: String
    /// Card colour (#194 C7); nil = the plain white card.
    let categoryId: String?
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    // Command-education card (#96 P2, adopted from pen `hTdkE`): the post-diagnosis
    // onboarding-2 content that teaches the English-only, screen-scoped command
    // grammar — the founder's discoverability gap. Buttons remain the fallback.
    static let all: [OnboardingFeature] = [
        .init(icon: "mic.fill", categoryId: "geography-world", title: #"Say "start""#, description: #"Say "start" after a question, or tap Start, to begin answering."#),
        .init(icon: "checklist", categoryId: "science-nature", title: "Five simple words", description: "start · ok · next · repeat · skip. That's the whole command set."),
        .init(icon: "globe", categoryId: "sports", title: "English by default", description: "Commands are spoken in English by default — Slovak command words can be enabled in Settings."),
        .init(icon: "hand.tap.fill", categoryId: nil, title: "Buttons always work", description: "Every command also has an on-screen button. Voice is optional."),
    ]
}

#if DEBUG
    #Preview("Welcome") {
        let vm = OnboardingViewModel(audioService: MockAudioService(), persistenceStore: MockPersistenceStore())
        OnboardingView(viewModel: vm)
    }

    #Preview("Features") {
        let vm = OnboardingViewModel(audioService: MockAudioService(), persistenceStore: MockPersistenceStore())
        vm.advance()
        return OnboardingView(viewModel: vm)
    }

    #Preview("Permission") {
        let vm = OnboardingViewModel(audioService: MockAudioService(), persistenceStore: MockPersistenceStore())
        vm.advance(); vm.advance()
        return OnboardingView(viewModel: vm)
    }
#endif
