//
//  ProfileStatTile.swift
//  Hangs
//
//  #213.4 (canvas "Lišta a Profil", Profil 1): one stat card in the Profile
//  grid. Unlocked: caption, value, one detail line. Locked: what is still
//  missing and a progress bar, on a dashed outline instead of a card.
//

import SwiftUI

struct ProfileStatTile: View {
    @Environment(\.locale) private var locale
    let card: StatCard

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            if let caption {
                Text(caption)
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .lineLimit(2)
            }
            if let content = card.content {
                unlocked(content)
            } else {
                locked
            }
        }
        .padding(Theme.Hangs.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.card.\(card.kind)")
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
        if card.isLocked {
            shape.strokeBorder(Theme.Hangs.Colors.subtleBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.fill(Theme.Hangs.Colors.bgCard)
        }
    }

    private var caption: LocalizedStringKey? {
        switch card.kind {
        case "totals": "In total"
        case "best_category": "Strong suit"
        case "weakest_category": "Room to grow"
        case "where": "Where you play"
        case "when": "When you play"
        case "typical_game": "Typical quiz"
        case "improvement": "Your progress"
        case "best_streak": "Best streak"
        case "hard_questions": "Hard questions"
        case "mcq_vs_open": "Options or own words"
        case "fastest_slowest": "Fastest category"
        default: nil
        }
    }

    // MARK: - Unlocked

    @ViewBuilder
    private func unlocked(_ content: StatCardContent) -> some View {
        switch content {
        case let .totals(answers, minutes):
            value(Text("\(answers) questions"))
            detail(Text(Duration.seconds(minutes * 60), format: .units(allowed: [.hours, .minutes], width: .abbreviated)))
        case let .bestCategory(category, accuracy), let .weakestCategory(category, accuracy):
            categoryValue(category)
            detail(Text("\(accuracy)% correct"))
        case let .fastestCategory(category, medianMs):
            categoryValue(category)
            detail(Text("\(Double(medianMs) / 1000, format: .number.precision(.fractionLength(1))) s to answer"))
        case let .whereYouPlay(place, share):
            value(Text(placeName(place)))
            detail(Text("\(share)% of quizzes"))
        case let .whenYouPlay(partOfDay, weekday):
            value(Text(partOfDayName(partOfDay)))
            if let weekday = weekdayLine(weekday) {
                detail(Text(weekday))
            }
        case let .typicalQuiz(minutes, answers):
            value(Text("\(minutes, format: .number.precision(.fractionLength(0 ... 1))) min"))
            detail(Text("\(answers) questions"))
        case let .improvement(deltaPoints, direction):
            switch direction {
            case "up": value(Text("+\(deltaPoints) points"), color: Theme.Hangs.Colors.live)
            case "down": value(Text("−\(abs(deltaPoints)) points"))
            default: value(Text("Holding steady"))
            }
            detail(Text("at the same difficulty"))
        case let .bestStreak(length):
            value(Text("\(length) in a row"))
            detail(Text("correct answers"))
        case let .hardQuestions(answers, accuracy):
            value(Text("\(accuracy)% correct"))
            detail(Text("\(answers) questions"))
        case let .choiceVsOwnAnswer(choiceAccuracy, ownAccuracy, better):
            value(Text(betterName(better)))
            detail(Text("options \(choiceAccuracy)%, own words \(ownAccuracy)%"))
        case .unknown:
            EmptyView()
        }
    }

    private func value(_ text: Text, color: Color = Theme.Hangs.Colors.ink) -> some View {
        text
            .font(.hangsLabel)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func detail(_ text: Text) -> some View {
        text
            .font(.hangsCaption)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .lineLimit(2)
    }

    private func categoryValue(_ id: String) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            Circle()
                .fill(Theme.Hangs.Category.style(for: id).fill)
                .frame(width: Metrics.dot, height: Metrics.dot)
                .accessibilityHidden(true)
            value(Text(verbatim: Config.categoryDisplayName(for: id, locale: locale) ?? ""))
        }
    }

    private func placeName(_ place: String) -> LocalizedStringKey {
        switch place {
        case "car": "In the car"
        case "bluetooth": "Over Bluetooth"
        case "speaker": "On the speaker"
        case "headphones": "In headphones"
        default: "Elsewhere"
        }
    }

    private func partOfDayName(_ part: String) -> LocalizedStringKey {
        switch part {
        case "morning": "In the morning"
        case "afternoon": "In the afternoon"
        case "evening": "In the evening"
        default: "At night"
        }
    }

    private func weekdayLine(_ weekday: String) -> LocalizedStringKey? {
        switch weekday {
        case "monday": "mostly on Mondays"
        case "tuesday": "mostly on Tuesdays"
        case "wednesday": "mostly on Wednesdays"
        case "thursday": "mostly on Thursdays"
        case "friday": "mostly on Fridays"
        case "saturday": "mostly on Saturdays"
        case "sunday": "mostly on Sundays"
        default: nil
        }
    }

    private func betterName(_ better: String) -> LocalizedStringKey {
        switch better {
        case "mcq": "Better with options"
        case "open": "Better in own words"
        default: "Equally good"
        }
    }

    // MARK: - Locked

    private var locked: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            Text(ProfileStatTile.remaining(card.progress))
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.mutedFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HangsProgressBar(progress: card.progress.fraction, tint: Theme.Hangs.Colors.liveAccent)
        }
    }

    /// "2 more quizzes": what a locked card or the first recap still needs.
    static func remaining(_ progress: StatCard.Progress) -> LocalizedStringKey {
        let left = progress.remaining
        return switch progress.unit {
        case "games": "\(left) more quizzes"
        case "answers": "\(left) more questions"
        case "days": "\(left) more days of play"
        case "categories": "\(left) more categories"
        default: "Keep playing"
        }
    }

    private enum Metrics {
        /// The category colour dot before the name (canvas `.dot`).
        static let dot: CGFloat = 8
    }
}
