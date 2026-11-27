//
//  DailyRoundEndView.swift
//  Hangs
//
//  #205.5 / #248.3 (founder 2026-11-25, variant B "Minimum"): the end of a
//  daily challenge is quiet. Close on the leading side and Share (an icon, as
//  Apple places it) on the trailing side; a small "Daily challenge · done"
//  label; the score as the headline; the round's tiles; one muted reward line;
//  the server's crowd sentence as one quiet line when it sends one (the server
//  decides when there are enough players, the client has no threshold).
//  Bottom: the listen bar, "Next quiz" (what spoken "again" does here: an
//  ordinary round, `playAgainFromRoundEnd`) and Home. The numbers stay as they
//  were when the screen opened (#240, 240.9); only what is still missing is
//  fetched. The week's crew table (#239) shows when the player has a crew.
//  Share sends the tiles and the score without the answers (#205.6).
//  #251: under the comparison, the round's questions with the answers.
//

import SwiftUI

struct DailyRoundEndView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var viewModel: QuizViewModel
    @StateObject private var daily: DailyChallengeViewModel
    /// #232 (daily text B): the same five questions as a link.
    @StateObject private var share: SharedQuizShareModel
    /// #239: the week's crew table under the result (nothing without a crew).
    @StateObject private var crew: DailyCrewViewModel
    private let round: DailyRound
    private let playerName: String

    private enum Metrics {
        /// The score figure, as on the regular round end.
        static let figure: CGFloat = 64
    }

    init(viewModel: QuizViewModel) {
        self.viewModel = viewModel
        let round = viewModel.activeDaily
            ?? DailyRound(day: DailyChallengeDay(.now), language: viewModel.settings.language)
        self.round = round
        _daily = StateObject(wrappedValue: DailyChallengeViewModel(
            network: viewModel.networkService,
            day: round.day,
            state: round.state
        ))
        _share = StateObject(wrappedValue: Self.shareModel(viewModel))
        _crew = StateObject(wrappedValue: DailyCrewViewModel(network: viewModel.networkService))
        playerName = Self.playerName()
    }

    #if DEBUG
        /// Test seam: a pre-loaded state, so snapshots need not wait on a fetch.
        init(
            viewModel: QuizViewModel,
            daily: DailyChallengeViewModel,
            crew: DailyCrewViewModel? = nil,
            playerName: String = "Jana"
        ) {
            self.viewModel = viewModel
            round = viewModel.activeDaily
                ?? DailyRound(day: daily.day, language: viewModel.settings.language)
            _daily = StateObject(wrappedValue: daily)
            _share = StateObject(wrappedValue: Self.shareModel(viewModel))
            _crew = StateObject(wrappedValue: crew ?? DailyCrewViewModel(network: viewModel.networkService))
            self.playerName = playerName
        }
    #endif

    private var content: DailyRoundEndContent {
        DailyRoundEndContent(state: daily.state, localMarks: viewModel.localDailyMarks, round: round)
    }

    var body: some View {
        VStack(spacing: 0) {
            HangsTopBar {
                HStack {
                    HangsNavChip(icon: "xmark", label: "Close") { viewModel.resetToHome() }
                        .accessibilityIdentifier("daily.close")
                    Spacer()
                    shareButton
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    scoreBlock
                    DailyMarkTiles(marks: content.marks, tileHeight: DailyMarkTiles.Metrics.roundEndTileHeight)
                        .accessibilityIdentifier("daily.tiles")
                    if let left = daily.bonusLeft {
                        DailyRewardLine(left: left)
                            .accessibilityIdentifier("daily.bonusLeft")
                    }
                    if let comparison = content.comparison {
                        Text(verbatim: comparison)
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("daily.comparison")
                    }
                    // #251: the round's questions with what the player said and
                    // the right answer (this phone's round only: a challenge
                    // played elsewhere has no list here).
                    if !viewModel.recapEntries.isEmpty {
                        HangsSectionLabel(text: "Questions")
                            .padding(.top, Theme.Hangs.Spacing.xs)
                        RecapAnswerList(viewModel: viewModel)
                            .accessibilityIdentifier("daily.questions")
                    }
                    // The invite card is gone (#248.3): the top-bar Share icon
                    // invites; the card draws only a crew that exists.
                    DailyCrewCard(model: crew, playerName: playerName, canInvite: false)
                    if let failure = share.failureMessage {
                        Text(verbatim: failure)
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .accessibilityIdentifier("daily.shareFailed")
                    }
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.sm)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            footer
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily.end")
        .task { await loadMissing() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadMissing() } }
        }
    }

    // MARK: - Score

    /// The label, then the score as the headline: the figure and "out of N".
    private var scoreBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            Text("Daily challenge · done")
                .textCase(.uppercase)
                .font(.hangsOverline)
                .tracking(0.6)
                .foregroundStyle(Theme.Hangs.Colors.sectionLabel)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                Text(verbatim: "\(content.score)")
                    .font(.hangsDisplay(Metrics.figure))
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("out of \(content.total)")
                    .font(.hangsSubHero)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Final score: \(String(content.score)) out of \(content.total)", bundle: .interface, locale: .interface, comment: "Accessibility label for the final-score card"))
            .accessibilityIdentifier("daily.score")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            // The round end listens for "ďalší" / "domov", named here as on
            // the regular round end.
            if viewModel.commandListenerHint != nil {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    recognizingWord: viewModel.recognizingWord,
                    heard: viewModel.commandHeard,
                    commandHint: viewModel.voiceHintWords,
                    language: viewModel.commandLanguage
                )
                .transition(.opacity)
            }
            VStack(spacing: Theme.Hangs.Spacing.xs) {
                HangsPrimaryButton(title: "Next quiz", trailingIcon: "arrow.right") {
                    viewModel.playAgainFromRoundEnd()
                }
                .accessibilityIdentifier("daily.nextQuiz")
                HangsSecondaryButton(title: "Home", icon: "house.fill") {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("daily.home")
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    /// #232: with the switch on and this phone's daily session at hand, the
    /// text carries a link to the same questions (made on the tap); else the
    /// text alone, as before. A top-bar icon, the place Apple gives Share.
    @ViewBuilder private var shareButton: some View {
        if viewModel.shareableRoundSessionId != nil {
            Button(action: shareWithLink) {
                HangsNavChipLabel(icon: "square.and.arrow.up", isLoading: share.isCreating)
            }
            .buttonStyle(.plain)
            .disabled(share.isCreating)
            .accessibilityLabel(Text("Share"))
            .accessibilityIdentifier("daily.share")
        } else {
            ShareLink(item: content.shareText) {
                HangsNavChipLabel(icon: "square.and.arrow.up", isLoading: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Share"))
            .accessibilityIdentifier("daily.share")
        }
    }

    /// What the screen could not show yet (opened before the server's summary,
    /// a failed fetch); what it shows already stays.
    private func loadMissing() async {
        async let state: Void = daily.loadIfMissing(day: round.day, language: round.language)
        async let table: Void = crew.loadIfMissing(day: round.day, language: round.language)
        _ = await (state, table)
    }

    /// The name the crew sees for this player (the one a shared link carries).
    private static func playerName() -> String {
        PlayerNameStore().playerName(accountName: KeychainTokenStore().load()?.accountName)
    }

    private func shareWithLink() {
        let content = content
        share.send(message: { _ in content.inviteText }, card: { _ in content.shareCard() })
    }

    private static func shareModel(_ viewModel: QuizViewModel) -> SharedQuizShareModel {
        SharedQuizShareModel(
            network: viewModel.networkService,
            source: viewModel.shareableRoundSessionId.map { .session($0) },
            previewTopic: { _ in String(localized: "Daily challenge", bundle: .interface, locale: .interface, comment: "#232: share sheet preview title of a daily challenge link") }
        )
    }
}
