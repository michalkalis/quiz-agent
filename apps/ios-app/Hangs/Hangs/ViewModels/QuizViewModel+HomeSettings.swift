//
//  QuizViewModel+HomeSettings.swift
//  Hangs
//
//  TestFlight build 90 feedback (Home variant A1, founder 2026-11-21): Home
//  opens Settings from its own gear and sets the round length in its settings
//  list, so both are tracked where they happen.
//

import Foundation

extension QuizViewModel {
    /// The gear at the top of Home.
    func settingsOpenedFromHome() {
        trackAnalytics(.homeSettingsOpened)
    }

    /// The "Number of questions" row on Home.
    func setQuestionCount(_ count: Int) {
        guard settings.numberOfQuestions != count else { return }
        settings.numberOfQuestions = count
        trackAnalytics(.homeRoundLengthChanged(questions: count))
    }
}
