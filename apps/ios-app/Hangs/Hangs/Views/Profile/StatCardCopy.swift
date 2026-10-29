//
//  StatCardCopy.swift
//  Hangs
//
//  #213: the words of one stat card: caption, value and one detail line.
//  Shared by the Profile tile (213.4) and the recap story (213.5), so a card
//  reads the same in both.
//

import SwiftUI

enum StatCardCopy {
    static func caption(_ kind: String) -> LocalizedStringKey? {
        switch kind {
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

    /// The headline number or name; a category reads as its display name.
    static func value(_ content: StatCardContent, locale: Locale) -> Text? {
        switch content {
        case let .totals(answers, _):
            Text("\(answers) questions")
        case let .bestCategory(category, _), let .weakestCategory(category, _), let .fastestCategory(category, _):
            Text(verbatim: Config.categoryDisplayName(for: category, locale: locale) ?? "")
        case let .whereYouPlay(place, _):
            Text(placeName(place))
        case let .whenYouPlay(partOfDay, _):
            Text(partOfDayName(partOfDay))
        case let .typicalQuiz(minutes, _):
            Text("\(minutes, format: .number.precision(.fractionLength(0 ... 1))) min")
        case let .improvement(deltaPoints, direction):
            switch direction {
            case "up": Text("+\(deltaPoints) points")
            case "down": Text("−\(abs(deltaPoints)) points")
            default: Text("Holding steady")
            }
        case let .bestStreak(length):
            Text("\(length) in a row")
        case let .hardQuestions(_, accuracy):
            Text("\(accuracy)% correct")
        case let .choiceVsOwnAnswer(_, _, better):
            Text(betterName(better))
        case .unknown:
            nil
        }
    }

    static func detail(_ content: StatCardContent) -> Text? {
        switch content {
        case let .totals(_, minutes):
            Text(Duration.seconds(minutes * 60), format: .units(allowed: [.hours, .minutes], width: .abbreviated))
        case let .bestCategory(_, accuracy), let .weakestCategory(_, accuracy):
            Text("\(accuracy)% correct")
        case let .fastestCategory(_, medianMs):
            Text("\(Double(medianMs) / 1000, format: .number.precision(.fractionLength(1))) s to answer")
        case let .whereYouPlay(_, share):
            Text("\(share)% of quizzes")
        case let .whenYouPlay(_, weekday):
            weekdayLine(weekday).map { Text($0) }
        case let .typicalQuiz(_, answers):
            Text("\(answers) questions")
        case .improvement:
            Text("at the same difficulty")
        case .bestStreak:
            Text("correct answers")
        case let .hardQuestions(answers, _):
            Text("\(answers) questions")
        case let .choiceVsOwnAnswer(choiceAccuracy, ownAccuracy, _):
            Text("options \(choiceAccuracy)%, own words \(ownAccuracy)%")
        case .unknown:
            nil
        }
    }

    private static func placeName(_ place: String) -> LocalizedStringKey {
        switch place {
        case "car": "In the car"
        case "bluetooth": "Over Bluetooth"
        case "speaker": "On the speaker"
        case "headphones": "In headphones"
        default: "Elsewhere"
        }
    }

    private static func partOfDayName(_ part: String) -> LocalizedStringKey {
        switch part {
        case "morning": "In the morning"
        case "afternoon": "In the afternoon"
        case "evening": "In the evening"
        default: "At night"
        }
    }

    private static func weekdayLine(_ weekday: String) -> LocalizedStringKey? {
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

    private static func betterName(_ better: String) -> LocalizedStringKey {
        switch better {
        case "mcq": "Better with options"
        case "open": "Better in own words"
        default: "Equally good"
        }
    }
}
