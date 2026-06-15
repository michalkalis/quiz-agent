//
//  OnboardingView.swift
//  Hangs
//
//  Onboarding flow bound to OnboardingViewModel (52.5 state machine).
//  Pages: Welcome (gkeCn) · Features (hTdkE) · Mic Access (haWJM) · Denied (COHnz).
//  #52 task 52.13.
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            switch viewModel.page {
            case .welcome: welcomePage
            case .features: featuresPage
            case .permission: permissionPage
            case .permissionDenied: deniedPage
            }

            Spacer()

            bottomControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.3), value: viewModel.page)
        .accessibilityIdentifier("onboarding.root")
    }

    // MARK: - Pages

    private var welcomePage: some View {
        VStack(spacing: 24) {
            Spacer()

            iconCircle(
                systemName: "mic.fill",
                bgColor: Theme.Hangs.Colors.pinkSoft,
                iconColor: Theme.Hangs.Colors.pink
            )

            headlineBlock(title: "ANSWER BY VOICE", accentColor: Theme.Hangs.Colors.pink)

            subtitle("Hangs reads questions aloud and listens for your answers. No tapping needed during a quiz.")

            Spacer()
            Spacer()
        }
        .accessibilityIdentifier("onboarding.welcome")
    }

    private var featuresPage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            VStack(spacing: 10) {
                Text("HANDS-FREE")
                    .font(.hangsDisplayMD)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                accentLine(color: Theme.Hangs.Colors.pink)

                subtitle("Perfect for driving, cooking, or walking.")
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 20)

            featuresCard
                .padding(.horizontal, 20)

            Spacer()
            Spacer()
        }
        .accessibilityIdentifier("onboarding.features")
    }

    private var permissionPage: some View {
        VStack(spacing: 24) {
            Spacer()

            iconCircle(
                systemName: "mic",
                bgColor: Theme.Hangs.Colors.pinkSoft,
                iconColor: Theme.Hangs.Colors.pink
            )

            headlineBlock(title: "MIC ACCESS", accentColor: Theme.Hangs.Colors.pink)

            subtitle("Hangs needs microphone access to hear your voice answers. You can also type answers as a fallback.")

            Spacer()
            Spacer()
        }
        .accessibilityIdentifier("onboarding.permission")
    }

    private var deniedPage: some View {
        VStack(spacing: 24) {
            Spacer()

            iconCircle(
                systemName: "mic.slash",
                bgColor: Theme.Hangs.Colors.warning.opacity(0.15),
                iconColor: Theme.Hangs.Colors.warning
            )

            headlineBlock(title: "MIC IS OFF", accentColor: Theme.Hangs.Colors.warning)

            subtitle("Voice answers need the mic. Turn it on in Settings, or keep playing by typing your answers.")

            Spacer()
            Spacer()
        }
        .accessibilityIdentifier("onboarding.denied")
    }

    // MARK: - Shared helpers

    private func iconCircle(systemName: String, bgColor: Color, iconColor: Color) -> some View {
        ZStack {
            Circle()
                .fill(bgColor)
                .frame(width: 120, height: 120)
            Image(systemName: systemName)
                .font(.system(size: 48))
                .foregroundColor(iconColor)
        }
        .accessibilityHidden(true)
    }

    private func headlineBlock(title: LocalizedStringKey, accentColor: Color) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.hangsDisplayMD)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            accentLine(color: accentColor)
        }
        .padding(.horizontal, 20)
    }

    private func accentLine(color: Color) -> some View {
        Capsule()
            .fill(color)
            .frame(width: 40, height: 3)
    }

    private func subtitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.hangsBody(15))
            .foregroundColor(Theme.Hangs.Colors.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .padding(.horizontal, 28)
    }

    // MARK: - Features card

    private var featuresCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(OnboardingFeature.all.enumerated()), id: \.offset) { index, feature in
                if index > 0 { HangsDivider() }
                featureRow(feature)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
                .hangsShadow(Theme.Hangs.Shadow.card)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func featureRow(_ feature: OnboardingFeature) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Hangs.Colors.pinkSoft)
                    .frame(width: 40, height: 40)
                Image(systemName: feature.icon)
                    .font(.system(size: 18))
                    .foregroundColor(Theme.Hangs.Colors.pink)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.hangsBody(15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                Text(feature.description)
                    .font(.hangsBody(13))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            HangsPageIndicator(
                pageCount: viewModel.pageCount,
                currentPage: viewModel.pageIndex,
                activeColor: viewModel.page == .permissionDenied
                    ? Theme.Hangs.Colors.warning
                    : Theme.Hangs.Colors.pink
            )
            .accessibilityIdentifier("onboarding.pageIndicator")

            primaryButton

            secondaryButton
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
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
            HangsGhostButton(title: "Skip", color: Theme.Hangs.Colors.muted) {
                viewModel.continueWithoutMic()
            }
            .accessibilityIdentifier("onboarding.skip")

        case .permission:
            HangsGhostButton(title: "Maybe later", color: Theme.Hangs.Colors.muted) {
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
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    static let all: [OnboardingFeature] = [
        .init(icon: "mic.fill", title: "Auto-Record", description: "Recording starts automatically after each question"),
        .init(icon: "hand.raised.fill", title: "Answer Anytime", description: "Start speaking to interrupt and answer immediately"),
        // Only promise commands the pipeline really handles (backend parser: skip/pass/next).
        // "repeat"/"score"/"help" are NOT implemented — repeatQuestion() has no caller yet.
        .init(icon: "bubble.left.fill", title: "Voice Commands", description: #"Say "skip", "pass", or "next" anytime"#),
        .init(icon: "forward.end.circle.fill", title: "Auto-Advance", description: "Results advance automatically — never tap"),
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
