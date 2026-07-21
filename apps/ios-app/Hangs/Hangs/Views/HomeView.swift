//
//  HomeView.swift
//  Hangs
//
//  Hangs redesign home screen — cream editorial aesthetic.
//  See docs/design/hangs-redesign-spec.md section "1. Home".
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow {
                NavigationLink(value: AppRoute.settings) {
                    navChipVisual(icon: "gearshape")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Settings", comment: "Accessibility label for the settings navigation button"))
                .accessibilityIdentifier("home.moreSettings")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("voice-based trivia for the road")
                        .font(.hangsBody(14))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    freePlanCard
                        .padding(.horizontal, 20)

                    HangsSectionLabel(text: "session", color: Theme.Hangs.Colors.pink)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    configCard
                        .padding(.horizontal, 20)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }

            // #77/#96 P2: listening indicator (pen `s49sd`) above the primary
            // action — visible only while the Home command window is armed.
            if let hint = viewModel.commandListenerHint {
                CmdListenBar(hint: hint)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            HangsPrimaryButton(
                title: "Start Quiz",
                icon: "play.fill",
                isLoading: viewModel.quizState == .startingQuiz
            ) {
                Task { await viewModel.startNewQuiz() }
            }
            .accessibilityIdentifier("home.startQuiz")
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .onAppear {
            viewModel.refreshAudioDevices()
            Task { await viewModel.refreshUsage() }
            // #77: arm the on-device English command listener on Home (idle) so
            // spoken "start" begins the quiz. Founder-overridable (default ON);
            // nothing leaves the device.
            if viewModel.voiceStartOnHomeEnabled {
                viewModel.refreshCommandWindow()
            }
        }
        .sheet(isPresented: $viewModel.showingMicrophonePicker) {
            AudioDevicePickerView(viewModel: viewModel)
        }
    }

    // MARK: - Free-plan quota card (#87)

    // Free users see remaining monthly questions + reset countdown; premium
    // users see an Unlimited row in the same slot (founder decision 2026-07-07).
    // Hidden until /usage has loaded.
    // #93 subscription IAP: for free users the whole card is a proactive
    // paywall entry point (Upgrade affordance + tap → presentPaywall()).
    @ViewBuilder
    private var freePlanCard: some View {
        if let usage = viewModel.usageInfo {
            if usage.isPremium {
                freePlanCardBody(usage)
            } else {
                Button {
                    viewModel.presentPaywall()
                } label: {
                    freePlanCardBody(usage)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.freePlanUpgradeButton")
            }
        }
    }

    private func freePlanCardBody(_ usage: UsageInfo) -> some View {
        HangsCard(padding: .init(top: 12, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.blue)
                            .accessibilityHidden(true)
                        if usage.isPremium {
                            Text("Unlimited questions")
                                .font(.hangsBody(13, weight: .semibold))
                                .foregroundColor(Theme.Hangs.Colors.ink)
                                .accessibilityIdentifier("home.freePlanUnlimited")
                        } else {
                            Text("\(usage.remaining ?? 0) of \(usage.questionsLimit ?? 0) free questions left")
                                .font(.hangsBody(13, weight: .semibold))
                                .foregroundColor(Theme.Hangs.Colors.ink)
                                .accessibilityIdentifier("home.freePlanCount")
                        }
                    }
                    Spacer()
                    if !usage.isPremium, let countdown = Self.resetCountdown(usage) {
                        Text(countdown)
                            .font(.hangsBody(12))
                            .foregroundColor(Theme.Hangs.Colors.mutedFaint)
                            .accessibilityIdentifier("home.freePlanReset")
                    }
                }
                if !usage.isPremium {
                    quotaTrack(fraction: Self.quotaFraction(usage))
                    HStack(spacing: 4) {
                        Text("Upgrade")
                            .font(.hangsBody(13, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(Theme.Hangs.Colors.pink)
                    .accessibilityIdentifier("home.freePlanUpgrade")
                }
            }
        }
        .accessibilityIdentifier("home.freePlanCard")
    }

    private func quotaTrack(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Hangs.Colors.subtleBorder)
                Capsule()
                    .fill(Theme.Hangs.Colors.blue)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    /// Fraction of the free quota still available (drives the track fill).
    static func quotaFraction(_ usage: UsageInfo) -> Double {
        guard let remaining = usage.remaining, let limit = usage.questionsLimit,
              limit > 0
        else { return 0 }
        return min(1, max(0, Double(remaining) / Double(limit)))
    }

    /// "resets in 3 days" — rounds up so it never promises a reset earlier
    /// than it happens. Nil when the backend timestamp doesn't parse.
    static func resetCountdown(_ usage: UsageInfo, now: Date = Date()) -> String? {
        guard let reset = usage.resetDate else { return nil }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 3600 else {
            return String(localized: "resets soon", comment: "Home quota card: free questions reset in under an hour")
        }
        if seconds >= 86400 {
            let days = Int((seconds / 86400).rounded(.up))
            return days == 1
                ? String(localized: "resets in 1 day", comment: "Home quota card: one day until the free-question reset")
                : String(localized: "resets in \(days) days", comment: "Home quota card: days until the free-question reset")
        }
        let hours = Int((seconds / 3600).rounded(.up))
        return String(localized: "resets in \(hours) hours", comment: "Home quota card: hours until the free-question reset")
    }

    // MARK: - Config card

    private var configCard: some View {
        HangsCard {
            VStack(spacing: 0) {
                languageRow
                HangsDivider()
                difficultyRow
                HangsDivider()
                categoriesRow
                // #96 P3: the "Image questions" toggle is hidden until image
                // content ships (founder, 2026-07-12). Wiring stays; only the UI
                // is gated behind a Config flag, so re-enabling is a one-line flip.
                if Config.imageQuestionsToggleVisible {
                    HangsDivider()
                    imageQuestionsRow
                }
            }
        }
    }

    // #82 item 4 (decision 7): every picker marks the active choice with a
    // checkmark; categories are multi-select (toggle membership, "All
    // Categories" clears the selection).

    private var languageRow: some View {
        Menu {
            ForEach(Language.supportedLanguages) { language in
                Button {
                    viewModel.settings.language = language.id
                } label: {
                    if viewModel.settings.language == language.id {
                        Label(language.nativeName, systemImage: "checkmark")
                    } else {
                        Text(language.nativeName)
                    }
                }
            }
        } label: {
            configRowVisual(
                label: "Language",
                value: Language.forCode(viewModel.settings.language)?.nativeName ?? "Unknown",
                valueColor: Theme.Hangs.Colors.blue
            )
        }
        .accessibilityIdentifier("home-language-menu")
    }

    private var difficultyRow: some View {
        Menu {
            ForEach(Config.difficultyOptions, id: \.0) { id, display in
                Button {
                    viewModel.settings.difficulty = id
                } label: {
                    if viewModel.settings.difficulty == id {
                        Label(display, systemImage: "checkmark")
                    } else {
                        Text(display)
                    }
                }
            }
        } label: {
            configRowVisual(
                label: "Difficulty",
                value: viewModel.settings.difficultyDisplayName(),
                valueColor: Theme.Hangs.Colors.blue
            )
        }
        .accessibilityIdentifier("home-difficulty-menu")
    }

    private var categoriesRow: some View {
        Menu {
            ForEach(Config.categoryOptions, id: \.id) { option in
                Button {
                    toggleCategory(option.id)
                } label: {
                    if isCategorySelected(option.id) {
                        Label(option.display, systemImage: "checkmark")
                    } else {
                        Text(option.display)
                    }
                }
            }
        } label: {
            configRowVisual(
                label: "Categories",
                value: viewModel.settings.categoryDisplayName(),
                valueColor: Theme.Hangs.Colors.blue
            )
        }
        .accessibilityIdentifier("home-categories-menu")
    }

    private func isCategorySelected(_ id: String?) -> Bool {
        guard let id else { return viewModel.settings.categories.isEmpty }
        return viewModel.settings.categories.contains(id)
    }

    private func toggleCategory(_ id: String?) {
        guard let id else {
            viewModel.settings.categories = []
            return
        }
        if let index = viewModel.settings.categories.firstIndex(of: id) {
            viewModel.settings.categories.remove(at: index)
        } else {
            viewModel.settings.categories.append(id)
        }
    }

    // #68: image questions are fun but unsuitable while driving — user-selectable
    // per session on Home, default OFF (founder decision 6, 2026-07-05).
    private var imageQuestionsRow: some View {
        HangsToggleRow(
            label: "Image questions",
            isOn: $viewModel.settings.includeImageQuestions
        )
        .accessibilityIdentifier("home-image-questions-toggle")
    }

    // MARK: - Row visual (replicates HangsConfigRow body w/o inner Button)

    private func configRowVisual(label: LocalizedStringKey, value: String, valueColor: Color) -> some View {
        HStack {
            Text(label)
                .font(.hangsBody(17, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Spacer()
            HStack(spacing: 6) {
                Text(value)
                    .font(.hangsBody(17, weight: .semibold))
                    .foregroundColor(valueColor)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(valueColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    // MARK: - Nav chip visual (used inside NavigationLink label)

    private func navChipVisual(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.navSquare)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .hangsShadow(Theme.Hangs.Shadow.navChip)
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            HomeView(viewModel: QuizViewModel.preview)
        }
    }
#endif
