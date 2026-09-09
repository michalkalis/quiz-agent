//
//  QuestionAvailability.swift
//  Hangs
//
//  Pre-flight corpus probe result (#174 finding 1)
//

import Foundation

/// How many unseen questions the backend could still serve for a configuration.
///
/// Matches `QuestionAvailabilityResponse` in `apps/quiz-agent/app/api/deps.py`.
/// Asked BEFORE a quiz starts so a set of 10 can never silently end after 3 —
/// the backend used to run out of eligible questions mid-quiz and finish the
/// session without saying why.
struct QuestionAvailability: Codable, Sendable, Equatable {
    let available: Int
    let requested: Int
    let sufficient: Bool
}

/// The "Not enough questions" alert's contents, set by `QuizViewModel` when the
/// probe comes back short and the quiz has NOT been started.
///
/// It carries the interrupted start's parameters so the alert's actions can be
/// pure functions of the value they were presented with. Re-reading the
/// view model's published state inside the button action would race SwiftUI's
/// own dismissal of the alert, which clears it.
struct QuestionShortfall: Sendable, Equatable {
    let available: Int
    let requested: Int
    /// Already-localized category label (`QuizSettings.categoryDisplayName()`),
    /// so the alert names the pool the user actually picked.
    let categoryName: String
    /// The interrupted `startNewQuiz` arguments; `nil` means "fall back to
    /// Settings", exactly as the original call did.
    let difficulty: String?
    let language: String?

    /// Whether "Start with N questions" is offered at all — a zero-question set
    /// is not a quiz, so at N == 0 the only ways forward are reset or cancel.
    var canStartShorter: Bool { available > 0 }
}
