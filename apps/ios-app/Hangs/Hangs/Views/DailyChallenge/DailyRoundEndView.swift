//
//  DailyRoundEndView.swift
//  Hangs
//
//  #205.5: the end of a daily challenge, in peak-end order: the round's
//  tiles, the score, how the player compares with today's crowd, and LAST
//  of the round the best hit (the rarest question they knew); the week's
//  crew table (#239) follows it. Every crowd sentence is the server's, shown
//  as sent; the screen never says "worse than". The numbers stay as they were
//  when the screen opened, since numbers changing under the player's eyes
//  confused (#240, 240.9); only what is still missing is fetched, and the next
//  opening shows the new numbers. No Play Again (one challenge a day) and no
//  upsell; Share sends the tiles and the score without the answers (#205.6).
//  #243 decision 5: it still says "Hotovo, 3 z 5. Znova, alebo domov?";
//  spoken "znova" starts an ordinary round (`playAgainFromRoundEnd`).
//

import SwiftUI

struct DailyRoundEndView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var viewModel: QuizViewModel
    @StateObject private var daily: DailyChallengeViewModel
    /// #232 (daily text B): the same five questions as a link.
    @StateObject private var share: SharedQuizShareModel
    /// #239: the week's crew table under the result.
    @StateObject private var crew: DailyCrewViewModel
    private let round: DailyRound
    private let playerName: String

    private enum Metrics {
        /// R-Complete: the score figure, as on the regular round end.
        static let figure: CGFloat = 52
        /// R-Complete: Home beside the main action.
        static let homeWidth: CGFloat = 124
        static let buttonHeight: CGFloat = 56
        static let shareIcon: CGFloat = 17
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
                HangsNavChip(icon: "xmark", label: "Close") { viewModel.resetToHome() }
                    .accessibilityIdentifier("daily.close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    HangsHeroBlock(title: "COMPLETE", titleFont: .hangsDisplaySM)
                    DailyMarkTiles(marks: content.marks, tileHeight: DailyMarkTiles.Metrics.roundEndTileHeight)
                        .accessibilityIdentifier("daily.tiles")
                    scoreCard
                    if let comparison = content.comparison {
                        comparisonCard(comparison)
                    }
                    if let bestHit = content.bestHit {
                        bestHitCard(bestHit)
                    }
                    if let left = daily.bonusLeft {
                        DailyBonusLeftLine(left: left)
                            .accessibilityIdentifier("daily.bonusLeft")
                    }
                    DailyCrewCard(
                        model: crew,
                        playerName: playerName,
                        canInvite: viewModel.shareableRoundSessionId != nil
                    )
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

    // MARK: - Cards

    private static let cardPadding = EdgeInsets(
        top: Theme.Hangs.Spacing.sm, leading: Theme.Hangs.Spacing.md,
        bottom: Theme.Hangs.Spacing.sm, trailing: Theme.Hangs.Spacing.md
    )

    private var scoreCard: some View {
        HangsCard(padding: Self.cardPadding) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                HangsSectionLabel(text: "final score")
                HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xxs) {
                    Text(verbatim: "\(content.score)")
                        .font(.hangsDisplay(Metrics.figure))
                        .foregroundStyle(Theme.Hangs.Colors.blue)
                        .lineLimit(1)
                    Text("out of \(content.total)")
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Final score: \(String(content.score)) out of \(content.total)", bundle: .interface, locale: .interface, comment: "Accessibility label for the final-score card"))
            .accessibilityIdentifier("daily.score")
        }
    }

    private func comparisonCard(_ comparison: String) -> some View {
        HangsCard(padding: Self.cardPadding) {
            Label {
                Text(verbatim: comparison)
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(Theme.Hangs.Colors.blue)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("daily.comparison")
    }

    private func bestHitCard(_ hit: DailyBestHit) -> some View {
        HangsCard(padding: Self.cardPadding) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                HangsSectionLabel(text: hit.rare ? "few knew this one" : "your best answer")
                Text(verbatim: hit.answer)
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: hit.question)
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: hit.text)
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .padding(.top, Theme.Hangs.Spacing.xxs)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("daily.bestHit")
    }

    // MARK: - Footer

    private var footer: some View {
        // From the size where button titles wrap, the two stack: a 124pt Home
        // beside Share would break "Home" mid-word (same rule as RoundCompleteView).
        let stacked = VStack(spacing: Theme.Hangs.Spacing.xs) {
            shareButton
            homeButton
        }
        return VStack(spacing: Theme.Hangs.Spacing.sm) {
            // #243 decision 5: the round end listens for "znova" / "domov",
            // named here as on the regular round end.
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
            if HangsButtonTitle.wraps(at: dynamicTypeSize) {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Hangs.Spacing.sm) {
                        shareButton
                        homeButton.frame(width: Metrics.homeWidth)
                    }
                    stacked
                }
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    /// #232: with the switch on and this phone's daily session at hand, the
    /// text carries a link to the same questions (made on the tap); else the
    /// text alone, as before.
    @ViewBuilder private var shareButton: some View {
        if viewModel.shareableRoundSessionId != nil {
            Button(action: shareWithLink) {
                shareLabel(isCreating: share.isCreating)
            }
            .buttonStyle(.plain)
            .disabled(share.isCreating)
            .accessibilityIdentifier("daily.share")
        } else {
            ShareLink(item: content.shareText) {
                shareLabel(isCreating: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("daily.share")
        }
    }

    /// The primary capsule's look on a `ShareLink` (a button cannot hold one).
    private func shareLabel(isCreating: Bool) -> some View {
        Label {
            Text("Share")
                .font(.hangsButton)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } icon: {
            if isCreating {
                ProgressView()
                    .tint(Theme.Hangs.Colors.textOnAction)
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: Metrics.shareIcon, weight: .semibold))
            }
        }
        .foregroundStyle(Theme.Hangs.Colors.textOnAction)
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
        .background(
            Capsule().fill(Theme.Hangs.Colors.action)
                .hangsShadow(Theme.Hangs.Shadow.cta)
        )
    }

    private var homeButton: some View {
        HangsSecondaryButton(title: "Home", icon: "house.fill") {
            viewModel.resetToHome()
        }
        .accessibilityIdentifier("daily.home")
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
        share.send { content.shareText(link: $0.url) }
    }

    private static func shareModel(_ viewModel: QuizViewModel) -> SharedQuizShareModel {
        SharedQuizShareModel(
            network: viewModel.networkService,
            source: viewModel.shareableRoundSessionId.map { .session($0) },
            previewTopic: { _ in String(localized: "Daily challenge", bundle: .interface, locale: .interface, comment: "#232: share sheet preview title of a daily challenge link") }
        )
    }
}
