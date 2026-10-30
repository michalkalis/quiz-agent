//
//  HomeView.swift
//  Hangs
//
//  Home — #194 C1 "Sklo nad kartami" (canvas R-Home), sections reordered by
//  the founder on 2026-10-13 (canvas "Home: poradie a plán", A + C + P1):
//  the quiz (category deck and its three setting pills) and my packs under
//  the same section label (#216.3: your plan moved to Profile); the slim
//  command bar and Start stay pinned at the bottom. #216.2 (founder 2026-10-30, P2): the logo is the
//  navigation bar's large title; on scroll the system swaps it for the
//  inline title "Play" (a `.title` logo item showed at rest too, so none).
//  Start is a bar over the content, which scrolls under it.
//

import SwiftUI

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingCategoryPicker = false
    @ObservedObject var viewModel: QuizViewModel
    /// #141: injected from ContentView so Home can list the account's custom
    /// packs — the app's one long-lived list model (#208.5). Nil (inspector
    /// tests / previews that don't exercise the packs section) renders Home
    /// without the section.
    var myPacks: MyPacksViewModel?
    /// #193 task 193.9: source of the server notice. Nil in inspector tests and
    /// previews, which then render Home without it.
    var appConfig: AppConfigStore?
    /// #205: today's daily challenge. Nil (inspector tests, previews) — or the
    /// server switch off — renders Home without the card.
    var dailyChallenge: DailyChallengeViewModel?
    /// Opens the custom-pack order sheet. Nil in inspector tests and previews,
    /// which then render Home without the create card.
    var onCreatePack: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Hangs.Spacing.xl) {
                // #205.4: the daily challenge opens the page, above the quiz.
                if let appConfig, let dailyChallenge {
                    HomeDailyChallengeSection(
                        appConfig: appConfig,
                        viewModel: dailyChallenge,
                        language: Language.selectable(viewModel.settings.language).id,
                        isStarting: viewModel.isStartingDailyChallenge,
                        isStartDisabled: viewModel.quizState == .startingQuiz,
                        onPlay: startDailyChallenge
                    )
                }

                if let appConfig {
                    UpdateAvailableCard(store: appConfig)
                    AppNoticeBanner(store: appConfig)
                }

                quizSection

                // #141: pick-and-play entry for owned custom packs, plus
                // the always-on "Create your own pack" row.
                if let myPacks {
                    HomePacksSection(
                        viewModel: myPacks,
                        createPack: createPackEntry,
                        quizStart: packQuizStart,
                        onPlayPack: startPack
                    )
                }

                // #96 P3: the "Image questions" toggle is hidden until
                // image content ships (founder, 2026-07-12). Wiring
                // stays; only the UI is gated behind a Config flag.
                if Config.imageQuestionsToggleVisible {
                    HangsCard { imageQuestionsRow }
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.sm)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) { bottomBar }
        .toolbar {
            ToolbarItem(placement: .largeTitle) {
                HangsBrandMark()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.large)
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
            HomeCategoryPicker(
                categories: $viewModel.settings.categories,
                includeLocalQuestions: $viewModel.settings.includeLocalQuestions
            )
        }
    }

    /// Start, with the listening indicator above it while Home's command
    /// window is armed (#77/#96 P2; #131 Track F: the one shared `ListenBar`,
    /// slim here — Home's command never changes and the screen has content).
    private var bottomBar: some View {
        VStack(spacing: Theme.Hangs.Spacing.xxs) {
            if viewModel.commandListenerHint != nil {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    recognizingWord: viewModel.recognizingWord,
                    commandHint: viewModel.voiceHintWords,
                    size: .slim,
                    language: viewModel.commandLanguage
                )
                .transition(.opacity)
            }
            startQuizButton
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
    }

    /// The pack whose start is running spins: the start request names it
    /// (#200), so a library start never spins a pack card.
    private var packQuizStart: HomePacksSection.QuizStart {
        HomePacksSection.QuizStart(
            isInFlight: viewModel.quizState == .startingQuiz,
            packId: viewModel.activePackId
        )
    }

    private func startPack(_ pack: PackPlay) {
        viewModel.beginQuizStart(pack: pack)
    }

    private func startDailyChallenge(_ day: DailyChallengeDay) {
        viewModel.beginDailyChallenge(day: day)
    }

    private var createPackEntry: HomePacksSection.CreatePackEntry? {
        guard let appConfig, let onCreatePack else { return nil }
        return HomePacksSection.CreatePackEntry(appConfig: appConfig, action: onCreatePack)
    }

    // MARK: - Sections (founder 2026-10-13: one label style for every section)

    private var quizSection: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            sectionLabel("Quiz")
            // The deck now opens the page, so it gets a fixed height instead
            // of whatever the content left: it overlapped the pills and lost
            // its bottom under Start once packs filled the screen.
            if !dynamicTypeSize.isAccessibilitySize {
                HomeCategoryDeck(
                    selectedCategories: viewModel.settings.categories,
                    title: viewModel.settings.categoryDisplayName(),
                    questionCount: viewModel.settings.numberOfQuestions
                )
                .frame(height: Metrics.deckHeight)
                // The fanned back cards turn on their bottom edge, so one
                // corner dips below the frame.
                .padding(.bottom, Theme.Hangs.Spacing.lg)
            }
            settingPills
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        HangsSectionLabel(text: text)
            .padding(.horizontal, Theme.Hangs.Spacing.xxs)
    }

    private enum Metrics {
        /// The deck's card height (`HomeCategoryDeck` cards are 196 × 256).
        static let deckHeight: CGFloat = 256
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
}

#if DEBUG
    #Preview {
        NavigationStack {
            HomeView(viewModel: QuizViewModel.preview, myPacks: MyPacksViewModel(service: MockPackOrderService()))
        }
    }
#endif
