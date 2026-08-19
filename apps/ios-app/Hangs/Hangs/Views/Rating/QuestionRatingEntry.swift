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

/// #109: the feedback chip next to the rating chip — same visual language.
/// Replaces the shake gesture, which misfired constantly in a moving car.
struct FeedbackEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.Hangs.Colors.bgCard))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Send feedback", comment: "Accessibility label for the TestFlight-only feedback button"))
        .accessibilityIdentifier("feedback.entry")
    }
}

private struct QuestionRatingEntryModifier: ViewModifier {
    let entry: QuestionRatingEntry?
    let questionId: String?
    let questionText: String?
    /// Insets that park the chip in the top chrome row, LEFT of whatever
    /// already sits at its trailing edge (settings gear / NN-NN counter). The
    /// trailing inset differs per screen because those elements differ — a
    /// single value clipped the question counter (sim check 2026-08-14).
    let topInset: CGFloat
    let trailingInset: CGFloat

    @State private var presentation: QuestionRatingPresentation?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let entry, entry.isEnabled, let questionId {
            content
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 8) {
                        if let openFeedback = entry.openFeedback {
                            FeedbackEntryButton(action: openFeedback)
                        }
                        QuestionRatingEntryButton {
                            presentation = QuestionRatingPresentation(
                                viewModel: entry.makeViewModel(questionId, questionText)
                            )
                        }
                    }
                    .padding(.trailing, trailingInset)
                    .padding(.top, topInset)
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
    /// `trailingInset` must clear whatever the screen already draws at the
    /// trailing edge of its top row.
    func questionRatingEntry(
        _ entry: QuestionRatingEntry?,
        questionId: String?,
        questionText: String? = nil,
        topInset: CGFloat = 17,
        trailingInset: CGFloat
    ) -> some View {
        modifier(
            QuestionRatingEntryModifier(
                entry: entry,
                questionId: questionId,
                questionText: questionText,
                topInset: topInset,
                trailingInset: trailingInset
            )
        )
    }
}
