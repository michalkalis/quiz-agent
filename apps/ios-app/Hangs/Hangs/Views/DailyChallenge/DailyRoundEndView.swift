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
//  fetched. Share sends the tiles and the score without the answers (#205.6).
//

import SwiftUI

struct DailyRoundEndView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var viewModel: QuizViewModel
    @StateObject private var daily: DailyChallengeViewModel
    /// #232 (daily text B): the same five questions as a link.
    @StateObject private var share: SharedQuizShareModel
    private let round: DailyRound

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
    }

    #if DEBUG
        /// Test seam: a pre-loaded state, so snapshots need not wait on a fetch.
        init(
            viewModel: QuizViewModel,
            daily: DailyChallengeViewModel
        ) {
            self.viewModel = viewModel
            round = viewModel.activeDaily
                ?? DailyRound(day: daily.day, language: viewModel.settings.language)
            _daily = StateObject(wrappedValue: daily)
            _share = StateObject(wrappedValue: Self.shareModel(viewModel))
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
        await daily.loadIfMissing(day: round.day, language: round.language)
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
