//
//  OnboardingView.swift
//  Hangs
//
//  Onboarding flow bound to OnboardingViewModel (52.5 state machine).
//  #237 (founder pick 2026-11-17, canvas A4 + A3): Microphone → Voice
//  commands, plus the mic-denied page. #194 C7: "Sklo nad kartami" restyle
//  (canvas Bg-Mic, Bg-MicDenied).
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale

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
        case .microphone: microphonePage
        case .commands: commandsPage
        case .permissionDenied: deniedPage
        }
    }

    // #194 C7: each page is one category-colour card with the page's glyph
    // (canvas Bg-Mic / Bg-MicDenied), then a left-aligned title and text.
    // Static: the illustration does not loop.
    /// #237: the first page, so it carries the AI services disclosure (#209).
    private var microphonePage: some View {
        illustratedPage(
            title: "MIC ACCESS",
            text: "Trubbo needs microphone access to hear your answers. You can also type them."
        ) {
            illustrationCard(categoryId: "movies-music") { style in
                glyphDisc(systemName: "mic.fill", glyph: style.fill, disc: Theme.Hangs.Category.chipFill)
            }
        } footer: {
            aiDisclosure
        }
        .accessibilityIdentifier("onboarding.permission")
    }

    /// #237 (canvas A3): what a command is, shown with three real ones, and
    /// that iOS will ask about speech recognition next.
    private var commandsPage: some View {
        illustratedPage(
            title: "VOICE COMMANDS",
            text: "Say “next” and you don't have to touch the phone. Handy when your hands are full."
        ) {
            illustrationCard(categoryId: "science-nature") { style in
                commandsIllustration(glyph: style.text)
            }
        } footer: {
            Label("Your iPhone will ask about speech recognition. You can answer by voice without commands.", systemImage: "info.circle")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.speechRecognitionNote")
        }
        .accessibilityIdentifier("onboarding.commands")
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
        text: LocalizedStringKey?,
        @ViewBuilder illustration: () -> some View,
        @ViewBuilder footer: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: Theme.Hangs.Spacing.md)
            illustration()
                .frame(maxWidth: .infinity)
            Spacer(minLength: Theme.Hangs.Spacing.xl)
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.lg) {
                textBlock(title: title, text: text)
                footer()
            }
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

    /// Three command words on white plates, staggered left → centre → right
    /// (canvas A3), under the "listening" waveform. The words follow the
    /// interface language, which is the quiz language and so the command one.
    private func commandsIllustration(glyph: Color) -> some View {
        let words = OnboardingViewModel.commandWords(
            language: .forQuizLanguage(locale.language.languageCode?.identifier ?? "en")
        )
        let alignments: [Alignment] = [.leading, .center, .trailing]
        return VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            Image(systemName: "waveform")
                .font(.hangsHeading)
                .foregroundStyle(glyph)
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(verbatim: word)
                    .font(.hangsHeading)
                    .foregroundStyle(Theme.Hangs.Category.chipText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .padding(.vertical, Theme.Hangs.Spacing.xs)
                    .background(Capsule().fill(Theme.Hangs.Category.chipFill))
                    .frame(maxWidth: .infinity, alignment: alignments[index % alignments.count])
            }
        }
        .padding(Theme.Hangs.Spacing.xl)
    }

    private func textBlock(title: LocalizedStringKey, text: LocalizedStringKey? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            Text(title)
                .font(.hangsDisplaySM)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .accessibilityAddTraits(.isHeader)
            if let text {
                Text(text)
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Metrics {
        /// Canvas illustration card (294 × 276) and the glyph disc on it.
        static let cardSize = CGSize(width: 294, height: 276)
        static let disc: CGFloat = 120
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

    /// #209 (App Review guideline 5.1.2(i)): before first use, name the AI
    /// services that process the player's spoken answers and typed pack topics.
    /// Kept to one short line; the provider list lives in the linked privacy
    /// policy and in the full notice in Settings. #237: it sits on the
    /// microphone page (the first one) above both of its buttons, so Allow and
    /// Maybe later are the consent (`OnboardingViewModel` records it).
    private var aiDisclosure: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            Text("Your answers and pack topics are processed by third-party AI services. By continuing, you agree.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.aiDisclosure")

            Button("Privacy Policy") {
                openURL(Config.privacyPolicyURL)
            }
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .accessibilityIdentifier("onboarding.privacyPolicy")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch viewModel.page {
        case .microphone:
            HangsPrimaryButton(title: "Allow Microphone", icon: "mic.fill") {
                Task { await viewModel.requestMicPermission() }
            }
            .accessibilityIdentifier("onboarding.allowMic")

        case .commands:
            HangsPrimaryButton(
                title: "Turn on commands",
                icon: "waveform",
                isLoading: viewModel.isEnablingCommands
            ) {
                Task { await viewModel.turnOnCommands() }
            }
            .accessibilityIdentifier("onboarding.enableCommands")

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
        case .microphone:
            HangsSecondaryButton(title: "Maybe later") {
                viewModel.continueWithoutMic()
            }
            .accessibilityIdentifier("onboarding.maybeLater")

        case .commands:
            HangsSecondaryButton(title: "Not now") {
                viewModel.skipCommands()
            }
            .disabled(viewModel.isEnablingCommands)
            .accessibilityIdentifier("onboarding.commandsNotNow")

        case .permissionDenied:
            HangsSecondaryButton(title: "Type answers instead", icon: "keyboard") {
                viewModel.continueWithoutMic()
            }
            .accessibilityIdentifier("onboarding.typeInstead")
        }
    }
}

#if DEBUG
    #Preview("Microphone") {
        OnboardingView(viewModel: OnboardingViewModel(
            audioService: MockAudioService(), persistenceStore: MockPersistenceStore(), enableCommands: {}
        ))
    }

    #Preview("Commands") {
        let vm = OnboardingViewModel(
            audioService: MockAudioService(), persistenceStore: MockPersistenceStore(), enableCommands: {}
        )
        Task { await vm.requestMicPermission() }
        return OnboardingView(viewModel: vm)
    }
#endif
