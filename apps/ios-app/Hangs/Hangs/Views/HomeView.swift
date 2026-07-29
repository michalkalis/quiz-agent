//
//  HomeView.swift
//  Hangs
//
//  Hangs redesign home screen — cream editorial aesthetic.
//  See docs/design/hangs-redesign-spec.md section "1. Home".
//

import SwiftUI
import UIKit

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

            // #77/#96 P2: listening indicator above the primary action — visible
            // only while the Home command window is armed. #131 Track F: the one
            // shared `ListenBar`, slim here — Home's command never changes and
            // the screen has content to show.
            if let hint = viewModel.commandListenerHint {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    commandHint: hint,
                    size: .slim
                )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            startQuizButton
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

    // MARK: - Start Quiz / Cancel (quiz-start in-button loading)

    // While `.startingQuiz` is in flight, the button flips to a still-tappable
    // "Cancel" control (spinner + xmark) instead of `isLoading` (which both
    // spins AND disables — Home now stays on screen during the start, per
    // ContentView routing, so cancelling mid-start must remain reachable).
    @ViewBuilder
    private var startQuizButton: some View {
        if viewModel.quizState == .startingQuiz {
            HangsPrimaryButton(
                title: "Cancel",
                icon: "xmark",
                showsSpinner: true
            ) {
                viewModel.cancelQuizStart()
            }
            .accessibilityIdentifier("home.cancelStart")
        } else {
            HangsPrimaryButton(
                title: "Start Quiz",
                icon: "play.fill"
            ) {
                viewModel.beginQuizStart()
            }
            .accessibilityIdentifier("home.startQuiz")
        }
    }

    // MARK: - Plan / entitlement card (#87 · #123 Track B)

    // The adaptive balance card (Variant A): one surface, one whole-card tap
    // target, six visuals derived from UsageInfo — free · free+credits ·
    // subscriber · subscriber+credits · grace · expired (rendered by
    // `HomePlanCard`). The tap destination forks by state: family A (free /
    // free+credits / expired) opens the paywall; family B (active / grace)
    // opens the manage-subscription surface.
    // #123 Track A: the slot is never silently blank — while /usage is still
    // in flight it shows a loading placeholder instead of disappearing.
    @ViewBuilder
    private var freePlanCard: some View {
        if let usage = viewModel.usageInfo {
            if HomePlanCard.state(for: usage).isManageSurface {
                Button {
                    openManageSubscriptions()
                } label: {
                    HomePlanCard(usage: usage)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.planManageButton")
            } else {
                Button {
                    viewModel.presentPaywall()
                } label: {
                    HomePlanCard(usage: usage)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.freePlanUpgradeButton")
            }
        } else if viewModel.usageLoadState == .failed {
            // Fetch failed with nothing cached (typically a Fly cold start) —
            // show a lightweight retry placeholder instead of silently
            // vanishing (#FIX2, CLAUDE.md Rule #2 fail-loud).
            freePlanCardUnavailable
        } else {
            // #123: still loading (the launch/foreground fetch hasn't
            // resolved yet).
            freePlanCardLoading
        }
    }

    /// Manage-subscription destination for an active/grace subscriber (#123
    /// Track B). The standard App Store account-subscriptions URL is the
    /// simplest reliable surface: it's one hop and needs no live UIWindowScene,
    /// unlike StoreKit's `AppStore.showManageSubscriptions(in:)`.
    private func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    // Shown only while /usage's launch/foreground fetch is still in flight and
    // nothing is cached yet (#123 Track A). Holds the loaded card's full
    // scaffold — the "your plan" label, a headline-height spinner row, an empty
    // track and a skeleton meta line — so the slot doesn't jump when /usage
    // resolves into the loaded (or failed) state.
    private var freePlanCardLoading: some View {
        HangsCard(padding: .init(top: 12, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 8) {
                Text("your plan")
                    .font(.hangsMono(11, weight: .medium))
                    .tracking(1)
                    .foregroundColor(Theme.Hangs.Colors.blueText)
                    .accessibilityIdentifier("home.planLabel")
                HStack(spacing: 6) {
                    ProgressView()
                        .tint(Theme.Hangs.Colors.muted)
                    Text("Loading your plan…")
                        .font(.hangsBody(13, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                    Spacer()
                }
                .frame(height: 40)
                Capsule()
                    .fill(Theme.Hangs.Colors.subtleBorder)
                    .frame(height: 4)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.Hangs.Colors.subtleBorder)
                    .frame(width: 96, height: 11)
                    .accessibilityIdentifier("home.planLoadingSkeleton")
            }
        }
        .accessibilityIdentifier("home.freePlanLoading")
    }

    // Shown only when /usage failed to load and there is nothing cached — a
    // tap re-fetches. Reuses the free-plan card styling; no new design system.
    private var freePlanCardUnavailable: some View {
        Button {
            Task { await viewModel.refreshUsage() }
        } label: {
            HangsCard(padding: .init(top: 12, leading: 16, bottom: 12, trailing: 16)) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .accessibilityHidden(true)
                    Text("Couldn't load your plan")
                        .font(.hangsBody(13, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Retry")
                            .font(.hangsBody(13, weight: .semibold))
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                    .foregroundColor(Theme.Hangs.Colors.pink)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.freePlanRetryButton")
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
                // #130: same scope wording as Settings — this picks the quiz
                // content language, not the interface language.
                label: "Quiz language",
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
