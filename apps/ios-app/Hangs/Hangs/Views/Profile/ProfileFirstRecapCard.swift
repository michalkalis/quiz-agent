//
//  ProfileFirstRecapCard.swift
//  Hangs
//
//  #213.4 (canvas "Nový hráč"): before the first recap, a ring of answers
//  so far and what is still missing (answers and days of play).
//

import SwiftUI

struct ProfileFirstRecapCard: View {
    let progress: FirstRecapProgress

    var body: some View {
        HangsCard(padding: EdgeInsets(top: Theme.Hangs.Spacing.md, leading: Theme.Hangs.Spacing.md, bottom: Theme.Hangs.Spacing.md, trailing: Theme.Hangs.Spacing.md)) {
            HStack(spacing: Theme.Hangs.Spacing.md) {
                ring
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text("Your first recap")
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                    if progress.answersLeft > 0 {
                        missing(ProfileStatTile.remaining(.init(current: progress.answers, target: progress.answersTarget, unit: "answers")))
                    }
                    if progress.daysLeft > 0 {
                        missing(ProfileStatTile.remaining(.init(current: progress.days, target: progress.daysTarget, unit: "days")))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.firstRecap")
    }

    private var ring: some View {
        let fraction = progress.answersTarget > 0 ? min(Double(progress.answers) / Double(progress.answersTarget), 1) : 0
        return ZStack {
            Circle()
                .stroke(Theme.Hangs.Colors.track, lineWidth: Metrics.ringWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Theme.Hangs.Colors.liveAccent, style: StrokeStyle(lineWidth: Metrics.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(verbatim: "\(min(progress.answers, progress.answersTarget))")
                    .font(.hangsHeading)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                Text("of \(progress.answersTarget)")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
        }
        .frame(width: Metrics.ring, height: Metrics.ring)
    }

    private func missing(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.hangsBody)
            .foregroundStyle(Theme.Hangs.Colors.muted)
    }

    private enum Metrics {
        /// The progress ring (canvas `.big-ring`, scaled to the card).
        static let ring: CGFloat = 76
        static let ringWidth: CGFloat = 8
    }
}
