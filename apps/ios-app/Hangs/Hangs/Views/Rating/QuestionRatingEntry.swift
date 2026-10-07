//
//  QuestionRatingEntry.swift
//  Hangs
//
//  The entry point to the #155 rating panel: the "Rate question" and "Send
//  feedback" rows of the quiz ⋯ menu (`QuizOverflowMenu`) on the question and
//  result screens. The floating chips are gone (#173 question, #188 G9 result).
//
//  Wired as an OPTIONAL value passed down from ContentView rather than read
//  from the environment, deliberately: QuestionView / ResultView are hosted
//  bare in unit tests, and an `@EnvironmentObject` lookup would crash every one
//  of them. Absent value (the default) = no affordance at all, which is also
//  exactly what an App Store build gets.
//
//  Temporary surface (D24): passing no entry to the two screens removes it
//  from the app.
//

import SwiftUI

/// How a screen builds a rating panel, and whether it may show one at all.
/// `isEnabled` is the TestFlight/Debug gate (`BuildChannel`), passed in as a
/// plain Bool so tests can force it either way.
struct QuestionRatingEntry {
    let isEnabled: Bool
    let makeViewModel: @MainActor (_ questionId: String, _ questionText: String?) -> QuestionRatingViewModel
    /// #109: opens the feedback sheet (ContentView owns the presentation, so
    /// the screenshot is captured before the sheet appears). Optional so tests
    /// and previews can build an entry without the feedback flow; nil = no
    /// feedback chip. Declared last so existing trailing-closure call sites
    /// keep binding to `makeViewModel`.
    var openFeedback: (() -> Void)? = nil
}

@MainActor
extension AppState {
    /// Build the rating entry for the live quiz (#155). The dictation services
    /// are the SAME shared instances the quiz answers use (`makeFeedbackVoice`),
    /// so the panel never spins up a second audio engine.
    func makeQuestionRatingEntry(for quizViewModel: QuizViewModel) -> QuestionRatingEntry {
        // Services captured by value — no cycle: nothing on AppState stores the
        // returned entry (ContentView rebuilds it per body pass).
        let ratingService = questionRatingService
        let networkService = self.networkService
        let voice = makeFeedbackVoice(for: quizViewModel)
        return QuestionRatingEntry(isEnabled: BuildChannel.debugSurfacesEnabled()) { questionId, questionText in
            QuestionRatingViewModel(
                questionId: questionId,
                questionText: questionText,
                ratingService: ratingService,
                networkService: networkService,
                voice: voice
            )
        }
    }
}
