//
//  DailyRoundEndView.swift
//  Hangs
//
//  #205.5: the end of a daily challenge, in peak-end order: the round's
//  tiles, the score, how the player compares with today's crowd, and LAST
//  the best hit (the rarest question they knew). Every crowd sentence is the
//  server's, shown as sent; the screen never says "worse than". The numbers
//  are fetched again whenever the screen shows, so they fill in as others
//  play. No Play Again (one challenge a day) and no upsell; Share sends the
//  tiles and the score without the answers (#205.6).
//

import SwiftUI

struct DailyRoundEndView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: QuizViewModel
    @StateObject private var daily: DailyChallengeViewModel
    private let round: DailyRound

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
    }

    #if DEBUG
        /// Test seam: a pre-loaded state, so snapshots need not wait on a fetch.
        init(viewModel: QuizViewModel, daily: DailyChallengeViewModel) {
            self.viewModel = viewModel
            round = viewModel.activeDaily
                ?? DailyRound(day: daily.day, language: viewModel.settings.language)
            _daily = StateObject(wrappedValue: daily)
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
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.sm)
            }

            footer
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily.end")
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                shareButton
                homeButton.frame(width: Metrics.homeWidth)
            }
            VStack(spacing: Theme.Hangs.Spacing.xs) {
                shareButton
                homeButton
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    /// The primary capsule's look on a `ShareLink` (a button cannot hold one).
    private var shareButton: some View {
        ShareLink(item: content.shareText) {
            Label {
                Text("Share")
                    .font(.hangsButton)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: Metrics.shareIcon, weight: .semibold))
            }
            .foregroundStyle(Theme.Hangs.Colors.textOnAction)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
            .background(
                Capsule().fill(Theme.Hangs.Colors.action)
                    .hangsShadow(Theme.Hangs.Shadow.cta)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("daily.share")
    }

    private var homeButton: some View {
        HangsSecondaryButton(title: "Home", icon: "house.fill") {
            viewModel.resetToHome()
        }
        .accessibilityIdentifier("daily.home")
    }

    private func refresh() async {
        await daily.refresh(day: round.day, language: round.language)
    }
}
