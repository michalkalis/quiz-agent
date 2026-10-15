//
//  HomeDailyChallengeSection.swift
//  Hangs
//
//  #205.4: the daily challenge card at the top of Home, shown only while the
//  server switch is on. Not played yet: five empty tiles and the play pill.
//  Played: the day's marks, the score and the server's live crowd line
//  ("Lepší ako 2 z 3 hráčov."); a tap opens the daily round end. The state is
//  fetched again every time Home appears, so the crowd line keeps up as
//  others play. A failed fetch shows the card to play (the start retries).
//

import SwiftUI

struct HomeDailyChallengeSection: View {
    @Environment(\.locale) private var locale
    @ObservedObject var appConfig: AppConfigStore
    @ObservedObject var viewModel: DailyChallengeViewModel
    /// The quiz language: the challenge is per language.
    let language: String
    /// A daily start is in flight: the pill spins.
    let isStarting: Bool
    /// Any start is in flight: the controls wait.
    let isStartDisabled: Bool
    /// Play the day's challenge, or (played) open its result.
    let onPlay: (DailyChallengeDay) -> Void

    private enum Metrics {
        static let pillHeight: CGFloat = 48
        static let cardPadding = EdgeInsets(
            top: Theme.Hangs.Spacing.md,
            leading: Theme.Hangs.Spacing.md,
            bottom: Theme.Hangs.Spacing.md,
            trailing: Theme.Hangs.Spacing.md
        )
    }

    var body: some View {
        if appConfig.config.dailyChallengeEnabled {
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.daily")
                .task(id: language) { await viewModel.refreshToday(language: language) }
        }
    }

    @ViewBuilder private var content: some View {
        switch viewModel.card {
        case .notPlayed:
            HangsCard(padding: Metrics.cardPadding) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    overline
                    Text("Five questions. The same for everyone.")
                        .font(.hangsHeading)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                    DailyMarkTiles(marks: Array(repeating: nil, count: viewModel.questionCount))
                        .accessibilityHidden(true)
                    HangsPrimaryButton(
                        title: "Play today's challenge",
                        icon: "play.fill",
                        isLoading: isStarting,
                        height: Metrics.pillHeight,
                        action: play
                    )
                    .disabled(isStartDisabled)
                    .accessibilityIdentifier("home.daily.play")
                }
            }
        case let .played(summary):
            Button(action: play) {
                HangsCard(padding: Metrics.cardPadding) {
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                        HStack(alignment: .firstTextBaseline) {
                            overline
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if isStarting {
                                ProgressView().tint(Theme.Hangs.Colors.muted)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.hangsCaption.weight(.bold))
                                    .foregroundStyle(Theme.Hangs.Colors.muted)
                                    .accessibilityHidden(true)
                            }
                        }
                        HStack(spacing: Theme.Hangs.Spacing.md) {
                            DailyMarkTiles(marks: DailyShareText.paddedMarks(summary.marks, total: summary.total))
                            Text(verbatim: "\(summary.score)/\(summary.total)")
                                .font(.hangsHeading)
                                .monospacedDigit()
                                .foregroundStyle(Theme.Hangs.Colors.ink)
                                .fixedSize()
                                .accessibilityIdentifier("home.daily.score")
                        }
                        if let comparison = summary.comparison {
                            Text(verbatim: comparison)
                                .font(.hangsBody)
                                .foregroundStyle(Theme.Hangs.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("home.daily.comparison")
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isStartDisabled)
            .accessibilityIdentifier("home.daily.open")
        }
    }

    private var overline: some View {
        HangsSectionLabel(text: "daily challenge · \(viewModel.day.label(languageCode: locale.language.languageCode?.identifier ?? "en"))")
    }

    private func play() {
        onPlay(viewModel.day)
    }
}
