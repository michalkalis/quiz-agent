//
//  HomeView.swift
//  Hangs
//
//  Home — #194 C1 "Sklo nad kartami" (canvas R-Home): plan card, my packs,
//  the category deck, three glass setting pills, then the slim command bar
//  and Start pinned at the bottom.
//

import SwiftUI
import UIKit

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingCategoryPicker = false
    @ObservedObject var viewModel: QuizViewModel
    /// #141: injected from ContentView so Home can list the account's custom
    /// packs. Nil (inspector tests / previews that don't exercise the packs
    /// section) renders Home without the section.
    var packOrderService: PackOrderServiceProtocol?
    /// #193 task 193.9: source of the server notice. Nil in inspector tests and
    /// previews, which then render Home without it.
    var appConfig: AppConfigStore?

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

            // The deck takes whatever height the content leaves; when the
            // content outgrows the screen (packs, notice, large text) the page
            // scrolls and the deck keeps only its floor. The reader sits
            // outside the scroll view, so measuring never feeds its own layout.
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: Theme.Hangs.Spacing.md) {
                        if let appConfig {
                            AppNoticeBanner(store: appConfig)
                        }

                        freePlanCard

                        // #141: pick-and-play entry for owned custom packs
                        // (variant B — founder 2026-08-05). Renders nothing for
                        // accounts without pack orders.
                        if let packOrderService {
                            HomePacksSection(service: packOrderService) { packId in
                                viewModel.beginQuizStart(packId: packId)
                            }
                        }

                        if !dynamicTypeSize.isAccessibilitySize {
                            HomeCategoryDeck(
                                selectedCategories: viewModel.settings.categories,
                                title: viewModel.settings.categoryDisplayName(),
                                questionCount: viewModel.settings.numberOfQuestions
                            )
                            .frame(minHeight: Metrics.deckFloor, maxHeight: .infinity)
                        }

                        settingPills

                        // #96 P3: the "Image questions" toggle is hidden until
                        // image content ships (founder, 2026-07-12). Wiring
                        // stays; only the UI is gated behind a Config flag.
                        if Config.imageQuestionsToggleVisible {
                            HangsCard { imageQuestionsRow }
                        }
                    }
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .padding(.vertical, Theme.Hangs.Spacing.sm)
                    .frame(minHeight: viewport.size.height, alignment: .top)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            // #77/#96 P2: listening indicator above the primary action — visible
            // only while the Home command window is armed. #131 Track F: the one
            // shared `ListenBar`, slim here — Home's command never changes and
            // the screen has content to show.
            if viewModel.commandListenerHint != nil {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    recognizingWord: viewModel.recognizingWord,
                    commandHint: viewModel.voiceHintWords,
                    size: .slim,
                    language: viewModel.commandLanguage
                )
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.top, Theme.Hangs.Spacing.xxs)
                .transition(.opacity)
            }

            startQuizButton
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.top, Theme.Hangs.Spacing.sm)
                .padding(.bottom, Theme.Hangs.Spacing.sm)
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
        .sheet(isPresented: $showingCategoryPicker) {
            HomeCategoryPicker(categories: $viewModel.settings.categories)
        }
    }

    private enum Metrics {
        /// Below this the fanned cards stop reading as a deck.
        static let deckFloor: CGFloat = 160
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
            // #174 (founder 2026-09-09): "Start" — the title IS the voice command.
            HangsPrimaryButton(
                title: "Start",
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
                    viewModel.presentPaywall(source: .home)
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
    // scaffold — the "your plan" label, a number-height spinner row, an empty
    // meter and a skeleton meta line — so the slot doesn't jump when /usage
    // resolves into the loaded (or failed) state.
    private var freePlanCardLoading: some View {
        HangsCard(padding: HomePlanCardMetrics.padding) {
            VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
                HomePlanCardLabel()
                HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                    Text(verbatim: "00")
                        .font(.hangsTitle)
                        .hidden()
                        .overlay(alignment: .leading) {
                            ProgressView().tint(Theme.Hangs.Colors.muted)
                        }
                    Text("Loading your plan…")
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                }
                HomePlanMeter(segments: [])
                Text(verbatim: "resets in 13 days")
                    .font(.hangsCaption)
                    .hidden()
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.Hangs.Colors.track)
                    }
                    .accessibilityIdentifier("home.planLoadingSkeleton")
            }
        }
        .accessibilityIdentifier("home.freePlanLoading")
    }

    // Shown only when /usage failed to load and there is nothing cached — a
    // tap re-fetches. Reuses the plan card surface; no new design system.
    private var freePlanCardUnavailable: some View {
        Button {
            Task { await viewModel.refreshUsage() }
        } label: {
            HangsCard(padding: HomePlanCardMetrics.padding) {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    Image(systemName: "bolt.slash")
                        .font(.hangsCaption.weight(.semibold))
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .accessibilityHidden(true)
                    Text("Couldn't load your plan")
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Hangs.Spacing.xxs) {
                        Text("Retry")
                            .font(.hangsLabel)
                        Image(systemName: "arrow.clockwise")
                            .font(.hangsCaption.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.Hangs.Colors.actionText)
                    .fixedSize()
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

    // MARK: - Setting pills (#194 C1, was the config card)

    // #82 item 4 (decision 7): every picker marks the active choice with a
    // checkmark; categories are multi-select (the picker sheet toggles
    // membership, "All Categories" clears the selection).

    /// Three pills side by side; stacked once the text is too large for a
    /// third of the width to hold "Slovenčina" on one line.
    private var settingPills: some View {
        let layout = dynamicTypeSize >= .xxLarge
            ? AnyLayout(VStackLayout(spacing: Theme.Hangs.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Theme.Hangs.Spacing.xs))
        return layout {
            languageMenu
            difficultyMenu
            categoriesButton
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var languageMenu: some View {
        Menu {
            ForEach(Language.selectableLanguages) { language in
                Button {
                    viewModel.settings.language = language.id
                } label: {
                    if viewModel.settings.language == language.id {
                        Label(language.nativeName, systemImage: "checkmark")
                    } else {
                        Text(language.nativeName)
                    }
                }
                .accessibilityIdentifier("home.language.\(language.id)")
            }
        } label: {
            // #130: same scope wording as Settings — this picks the quiz
            // content language, not the interface language.
            HomeSettingPill(
                caption: "Quiz language",
                value: Language.selectable(viewModel.settings.language).nativeName
            )
        }
        .accessibilityIdentifier("home-language-menu")
    }

    private var difficultyMenu: some View {
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
                .accessibilityIdentifier("home.difficulty.\(id)")
            }
        } label: {
            HomeSettingPill(
                caption: "Difficulty",
                value: viewModel.settings.difficultyDisplayName()
            )
        }
        .accessibilityIdentifier("home-difficulty-menu")
    }

    private var categoriesButton: some View {
        Button {
            showingCategoryPicker = true
        } label: {
            HomeSettingPill(
                caption: "Categories",
                value: viewModel.settings.categoryDisplayName(),
                valueLineLimit: 2
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-categories-menu")
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

    // MARK: - Nav chip visual (used inside NavigationLink label)

    private func navChipVisual(icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .frame(width: 44, height: 44)
            // #194 B2: same glass circle as `HangsNavChip`.
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            HomeView(viewModel: QuizViewModel.preview, packOrderService: MockPackOrderService())
        }
    }
#endif
