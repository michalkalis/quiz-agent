//
//  QuestionRatingEntry.swift
//  Hangs
//
//  The entry point to the #155 rating panel: a small star chip overlaid on the
//  question and result screens, plus the sheet it opens.
//
//  Wired as an OPTIONAL value passed down from ContentView rather than read
//  from the environment, deliberately: QuestionView / ResultView are hosted
//  bare in unit tests, and an `@EnvironmentObject` lookup would crash every one
//  of them. Absent value (the default) = no affordance at all, which is also
//  exactly what an App Store build gets.
//
//  Temporary surface (D24): deleting the two `.questionRatingEntry(…)` call
//  sites removes it from the app.
//

import SwiftUI

/// How a screen builds a rating panel, and whether it may show one at all.
/// `isEnabled` is the TestFlight/Debug gate (`BuildChannel`), passed in as a
/// plain Bool so tests can force it either way.
struct QuestionRatingEntry {
    let isEnabled: Bool
    let makeViewModel: @MainActor (_ questionId: String, _ questionText: String?) -> QuestionRatingViewModel
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

/// The chip itself — small, muted, and out of the way of the quiz chrome.
struct QuestionRatingEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "star.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.Hangs.Colors.bgCard))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Rate this question", comment: "Accessibility label for the TestFlight-only question rating button"))
        .accessibilityIdentifier("rating.entry")
    }
}

private struct QuestionRatingEntryModifier: ViewModifier {
    let entry: QuestionRatingEntry?
    let questionId: String?
    let questionText: String?

    @State private var presentation: QuestionRatingPresentation?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let entry, entry.isEnabled, let questionId {
            content
                .overlay(alignment: .topTrailing) {
                    QuestionRatingEntryButton {
                        presentation = QuestionRatingPresentation(
                            viewModel: entry.makeViewModel(questionId, questionText)
                        )
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 58)
                }
                .sheet(item: $presentation) { presentation in
                    QuestionRatingSheet(viewModel: presentation.viewModel)
                }
        } else {
            content
        }
    }
}

extension View {
    /// Overlay the TestFlight-only rating chip and its panel. No-op when the
    /// entry is absent/disabled or there is no question to rate.
    func questionRatingEntry(
        _ entry: QuestionRatingEntry?,
        questionId: String?,
        questionText: String? = nil
    ) -> some View {
        modifier(
            QuestionRatingEntryModifier(entry: entry, questionId: questionId, questionText: questionText)
        )
    }
}
