//
//  QuizSettings.swift
//  CarQuiz
//
//  Centralized quiz configuration model
//

import Foundation

/// Comprehensive quiz settings model
/// Persisted to UserDefaults for cross-session configuration
struct QuizSettings: Codable, Equatable, Sendable {
    // MARK: - Properties

    /// Language ISO 639-1 code (e.g., "en", "sk", "de")
    var language: String

    /// Audio mode identifier ("call" or "media")
    var audioMode: String

    /// Number of questions per quiz session
    var numberOfQuestions: Int

    /// Optional category filter (nil = all categories, "adults", "general")
    var category: String?

    /// Difficulty level ("easy", "medium", "hard", "random")
    var difficulty: String

    /// Auto-advance delay in seconds for result screen
    var autoAdvanceDelay: Int

    /// Answer time limit in seconds (0 = Off, no auto-recording)
    var answerTimeLimit: Int

    /// Preferred input device UID (nil = automatic selection)
    var preferredInputDeviceId: String?

    // MARK: - Default Configuration

    /// Default settings matching app defaults
    static let `default` = QuizSettings(
        language: "en",
        audioMode: "media",
        numberOfQuestions: 10,
        category: nil,  // All categories
        difficulty: "medium",
        autoAdvanceDelay: 8,
        answerTimeLimit: 30,
        preferredInputDeviceId: nil  // Automatic
    )

    // MARK: - Validation Helpers

    /// Valid question count options
    static let questionCountOptions = [5, 10, 15, 20]

    /// Valid difficulty options
    static let difficultyOptions = ["easy", "medium", "hard", "random"]

    /// Valid auto-advance delay options (seconds)
    static let autoAdvanceDelayOptions = [5, 8, 10, 15]

    /// Valid answer time limit options (seconds, 0 = Off)
    static let answerTimeLimitOptions = [0, 15, 20, 30, 45, 60]

    /// Valid category options (nil means "All Categories")
    static let categoryOptions: [String?] = [nil, "adults", "general"]

    /// Display name for category (handles nil case)
    func categoryDisplayName() -> String {
        switch category {
        case nil:
            return "All Categories"
        case "adults":
            return "Adults"
        case "general":
            return "General"
        default:
            return "Unknown"
        }
    }

    /// Difficulty display name (capitalize first letter)
    func difficultyDisplayName() -> String {
        difficulty.prefix(1).uppercased() + difficulty.dropFirst()
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension QuizSettings {
    static let previewCustom = QuizSettings(
        language: "sk",
        audioMode: "media",
        numberOfQuestions: 20,
        category: "adults",
        difficulty: "hard",
        autoAdvanceDelay: 5,
        answerTimeLimit: 45,
        preferredInputDeviceId: nil
    )
}
#endif
