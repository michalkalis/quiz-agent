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
//  #236 (canvas „B · rozpracované“ F1–F4): the switch "Kvíz | S deťmi" on top
//  turns Home into the family version while the server lists topics: the
//  deck shows the age band's topics, Vek and Téma replace Náročnosť and
//  Kategórie, Start reads "Štart s deťmi" under the line that the adult
//  answers; the daily challenge, "Choose several" and Quick quiz hide.
//  TestFlight build 90 (variant A1, founder 2026-11-21): a gear at the top
//  opens Settings, and one grouped list under the deck (quiz language,
//  difficulty, number of questions, Quick quiz) replaces the three pills and
//  the loose toggle row.
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
    /// #232: a friend's quiz link; nil (inspector tests, previews) renders Home
    /// without the first-launch paste row.
    var sharedQuiz: SharedQuizInbox?
    /// Opens the custom-pack order sheet. Nil in inspector tests and previews,
    /// which then render Home without the create card.
    var onCreatePack: (() -> Void)?
    /// Pushes Settings from the gear. Nil in inspector tests and previews,
    /// where the gear does nothing.
    var onOpenSettings: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Hangs.Spacing.xl) {
                // #236: only while the server lists topics for this build.
                if viewModel.isFamilyModeAvailable {
                    modePicker
                }

                // #232: the first launch's "quiz link from a friend?" row.
                if let appConfig, let sharedQuiz {
                    HomeSharedQuizPasteRow(inbox: sharedQuiz, appConfig: appConfig)
                }

                // #205.4: the daily challenge opens the page, above the quiz.
                // #236: it is for adults, so the family version leaves it out.
                if let appConfig, let dailyChallenge, !viewModel.isFamilyModeOn {
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
                        onSendPack: sendPackAction,
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
            ToolbarItem(placement: .topBarTrailing) { settingsButton }
        }
        .navigationTitle("Play")
        .navigationBarTitleDisplayMode(.large)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .onAppear {
            viewModel.refreshAudioDevices()
            Task { await viewModel.refreshUsage() }
        }
        .task(id: familyTopicsRequest) {
            await viewModel.refreshFamilyTopics(enabled: familyTopicsRequest.enabled, language: familyTopicsRequest.language)
        }
        .sheet(isPresented: $viewModel.showingFamilyBandSheet) {
            FamilyBandSheet(
                bands: viewModel.familyBands,
                selected: viewModel.familySettings.band,
                onSelect: viewModel.selectFamilyBand,
                onClose: viewModel.dismissFamilyBandSheet
            )
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

    /// The Start button; Home has no voice commands (#224). #236: in the
    /// family version the line that the adult answers sits above it.
    private var bottomBar: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            if viewModel.isFamilyModeOn {
                Text("You answer, the kids guess along with you.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.family.adultAnswers")
            }
            startQuizButton
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
    }

    // MARK: - Family mode (#236)

    /// What the topics fetch depends on: the server switch and the quiz language.
    private struct FamilyTopicsRequest: Equatable {
        let enabled: Bool
        let language: String
    }

    private var familyTopicsRequest: FamilyTopicsRequest {
        FamilyTopicsRequest(
            enabled: appConfig?.familyModeEnabled == true,
            language: Language.selectable(viewModel.settings.language).id
        )
    }

    /// Canvas F1–F4: a compact segmented switch, leading. While the age sheet
    /// of the first flip is up it already shows "S deťmi".
    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { viewModel.isFamilyModeOn || viewModel.showingFamilyBandSheet },
            set: { viewModel.setFamilyMode($0) }
        )) {
            Text("Quiz").tag(false)
                .accessibilityIdentifier("home.mode.quiz")
            Text("With kids").tag(true)
                .accessibilityIdentifier("home.mode.family")
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("home.mode")
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

    /// #232: "Send to a friend" in a finished pack's menu, with the switch on.
    private var sendPackAction: ((OrderSnapshot) -> Void)? {
        guard appConfig?.sharedQuizEnabled == true else { return nil }
        return sendPack
    }

    private func sendPack(_ order: OrderSnapshot) {
        guard let packId = order.packId else { return }
        viewModel.sendPack(packId: packId)
    }

    private func startDailyChallenge(_ day: DailyChallengeDay) {
        viewModel.beginDailyChallenge(day: day)
    }

    private var createPackEntry: HomePacksSection.CreatePackEntry? {
        guard let appConfig, let onCreatePack else { return nil }
        return HomePacksSection.CreatePackEntry(appConfig: appConfig, action: onCreatePack)
    }

    // MARK: - Sections (founder 2026-10-13: one label style for every section)

    @ViewBuilder
    private var quizSection: some View {
        if viewModel.isFamilyModeOn, let band = viewModel.familySettings.band {
            familySection(band)
        } else {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    sectionLabel("Quiz")
                    Spacer(minLength: Theme.Hangs.Spacing.sm)
                    // #224.6 (canvas C4): the deck steps one category per tap, so
                    // the multi-select picker gets its own entry beside the label.
                    if !dynamicTypeSize.isAccessibilitySize {
                        chooseSeveralButton
                    }
                }
                // The deck now opens the page, so it gets a fixed height instead
                // of whatever the content left: it overlapped the pills and lost
                // its bottom under Start once packs filled the screen.
                if !dynamicTypeSize.isAccessibilitySize {
                    HomeCategoryDeck(
                        selectedCategories: viewModel.settings.categories,
                        title: viewModel.settings.categoryDisplayName(),
                        questionCount: viewModel.settings.numberOfQuestions,
                        onStep: { viewModel.stepCategory($0, input: $1) }
                    )
                    .frame(height: Metrics.deckHeight)
                    // The fanned back cards turn on their bottom edge, so one
                    // corner dips below the cards: the page dots' gap holds it.
                }
                quizSettingsList
            }
        }
    }

    /// #236 (canvas F2–F4): the band's topics on the deck, one per round.
    /// A band with nothing to play keeps its pills, so another age is one tap.
    private func familySection(_ band: FamilyBand) -> some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            sectionLabel("Topics for \(band.label)")
            if !dynamicTypeSize.isAccessibilitySize, let topic = viewModel.familyTopic {
                HomeCategoryDeck(
                    cards: HomeDeckCard.topics(viewModel.familyBandTopics),
                    front: viewModel.familyBandTopics.firstIndex(of: topic) ?? 0,
                    title: topic.name,
                    questionCount: topic.roundSize,
                    label: "Topic",
                    identifier: "home.familyDeck",
                    onStep: { direction, _ in viewModel.stepFamilyTopic(direction) }
                )
                .frame(height: Metrics.deckHeight)
            }
            quizSettingsList
        }
    }

    /// #224.8 (canvas D2): "Quick quiz", the last row of the list. Off = today's flow.
    private var quickGameRow: some View {
        HangsToggleRow(
            label: "Quick quiz",
            subtitle: "After \"Next\": next question, no explanation",
            isOn: Binding(get: { viewModel.settings.quickGame }, set: { viewModel.setQuickGame($0) })
        )
        .accessibilityIdentifier("home.quickGame")
    }

    private var settingsButton: some View {
        Button {
            onOpenSettings?()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("home.settings")
    }

    private var chooseSeveralButton: some View {
        HangsGhostButton(title: "Choose several", icon: "checklist") {
            viewModel.categoryPickerOpened(from: .deckButton)
            showingCategoryPicker = true
        }
        .fixedSize()
        .accessibilityIdentifier("home.categories.chooseSeveral")
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        HangsSectionLabel(text: text)
            .padding(.horizontal, Theme.Hangs.Spacing.xxs)
    }

    private enum Metrics {
        /// The deck's card height plus the page dots under it.
        static let deckHeight: CGFloat = DeckMetrics.cardSize.height + DeckMetrics.dotsGap + DeckMetrics.dotsHeight
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
        } else if viewModel.isFamilyModeOn {
            // #236: the mode is remembered, so Start names it (founder 2026-11-18).
            HangsPrimaryButton(
                title: "Start with kids",
                icon: "play.fill"
            ) {
                viewModel.beginFamilyStart()
            }
            .disabled(viewModel.familyRound == nil)
            .accessibilityIdentifier("home.startFamily")
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
            return String(localized: "resets soon", bundle: .interface, locale: .interface, comment: "Home quota card: free questions reset in under an hour")
        }
        if seconds >= 86400 {
            let days = Int((seconds / 86400).rounded(.up))
            return days == 1
                ? String(localized: "resets in 1 day", bundle: .interface, locale: .interface, comment: "Home quota card: one day until the free-question reset")
                : String(localized: "resets in \(days) days", bundle: .interface, locale: .interface, comment: "Home quota card: days until the free-question reset")
        }
        let hours = Int((seconds / 3600).rounded(.up))
        return String(localized: "resets in \(hours) hours", bundle: .interface, locale: .interface, comment: "Home quota card: hours until the free-question reset")
    }

    // MARK: - Settings list (TestFlight build 90, variant A1)

    // #82 item 4 (decision 7): every picker marks the active choice with a
    // checkmark; categories are multi-select (the picker sheet toggles
    // membership, "All Categories" clears the selection).

    /// One grouped list under the deck, as in the iPhone's Settings. The deck
    /// and its "Choose several" hide at accessibility text sizes, so the
    /// categories get a row there instead.
    private var quizSettingsList: some View {
        HangsCard {
            VStack(spacing: 0) {
                languageMenu
                hairline
                if viewModel.isFamilyModeOn {
                    bandMenu
                    hairline
                    topicMenu
                } else {
                    difficultyMenu
                    hairline
                    if dynamicTypeSize.isAccessibilitySize {
                        categoriesButton
                        hairline
                    }
                    questionCountMenu
                    hairline
                    quickGameRow
                }
            }
        }
    }

    private var hairline: some View {
        HangsDivider()
            .padding(.leading, Theme.Hangs.Spacing.md)
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
            HangsConfigRowLabel(
                label: "Quiz language",
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
            HangsConfigRowLabel(
                label: "Difficulty",
                value: viewModel.settings.difficultyDisplayName()
            )
        }
        .accessibilityIdentifier("home-difficulty-menu")
    }

    private var questionCountMenu: some View {
        Menu {
            ForEach(QuizSettings.questionCountOptions, id: \.self) { count in
                Button {
                    viewModel.setQuestionCount(count)
                } label: {
                    if viewModel.settings.numberOfQuestions == count {
                        Label(String(count), systemImage: "checkmark")
                    } else {
                        Text(verbatim: String(count))
                    }
                }
                .accessibilityIdentifier("home.questionCount.\(count)")
            }
        } label: {
            HangsConfigRowLabel(
                label: "Number of questions",
                value: String(viewModel.settings.numberOfQuestions)
            )
        }
        .accessibilityIdentifier("home.questionCount")
    }

    /// #236: "Vek" replaces "Náročnosť" (canvas F3).
    private var bandMenu: some View {
        Menu {
            ForEach(viewModel.familyBands, id: \.self) { band in
                Button {
                    viewModel.selectFamilyBand(band)
                } label: {
                    if viewModel.familySettings.band == band {
                        Label(band.label, systemImage: "checkmark")
                    } else {
                        Text(verbatim: band.label)
                    }
                }
                .accessibilityLabel(Text(band.spokenLabel))
                .accessibilityIdentifier("home.band.\(band.rawValue)")
            }
        } label: {
            HangsConfigRowLabel(label: "Age", value: viewModel.familySettings.band?.label ?? "")
        }
        .accessibilityValue(viewModel.familySettings.band.map { Text($0.spokenLabel) } ?? Text(verbatim: ""))
        .accessibilityIdentifier("home.band.menu")
    }

    /// #236: the topic, also the way to change it where the deck hides
    /// (accessibility text sizes).
    private var topicMenu: some View {
        Menu {
            ForEach(viewModel.familyBandTopics) { topic in
                Button {
                    viewModel.selectFamilyTopic(topic.key)
                } label: {
                    if viewModel.familyTopic == topic {
                        Label(topic.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: topic.name)
                    }
                }
                .accessibilityIdentifier("home.topic.\(topic.key)")
            }
        } label: {
            HangsConfigRowLabel(label: "Topic", value: viewModel.familyTopic?.name ?? "")
        }
        .accessibilityIdentifier("home.topic.menu")
    }

    private var categoriesButton: some View {
        HangsConfigRow(label: "Categories", value: viewModel.settings.categoryDisplayName()) {
            viewModel.categoryPickerOpened(from: .pill)
            showingCategoryPicker = true
        }
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
