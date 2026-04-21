//
//  QuizSettings.swift
//  Hangs
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

    /// Answer time limit in seconds (0 = Off). MCQ: auto-skips on expiry. Voice: auto-starts recording.
    var answerTimeLimit: Int

    /// Thinking time in seconds before auto-recording starts (0 = immediate 500ms delay)
    var thinkingTime: Int

    /// Preferred input device UID (nil = automatic selection)
    var preferredInputDeviceId: String?

    /// Whether auto-record is enabled (auto-start recording after TTS + silence detection to auto-stop)
    /// Requires iOS 26+ for SpeechDetector VAD
    var autoRecordEnabled: Bool

    /// Whether to auto-confirm transcribed answers after a 2s countdown
    /// When enabled, skips the confirmation modal — say "re-record" to cancel
    var autoConfirmEnabled: Bool

    /// Whether to show the answer confirmation sheet before submitting
    /// When disabled, answers are submitted immediately after transcription
    var showConfirmSheet: Bool

    /// Whether TTS audio playback is muted (questions still display visually)
    var isMuted: Bool

    // MARK: - Memberwise Init

    init(
        language: String,
        audioMode: String,
        numberOfQuestions: Int,
        category: String?,
        difficulty: String,
        autoAdvanceDelay: Int,
        answerTimeLimit: Int,
        thinkingTime: Int = 60,
        preferredInputDeviceId: String?,
        autoRecordEnabled: Bool = true,
        autoConfirmEnabled: Bool = true,
        showConfirmSheet: Bool = true,
        isMuted: Bool = false
    ) {
        self.language = language
        self.audioMode = audioMode
        self.numberOfQuestions = numberOfQuestions
        self.category = category
        self.difficulty = difficulty
        self.autoAdvanceDelay = autoAdvanceDelay
        self.answerTimeLimit = answerTimeLimit
        self.thinkingTime = thinkingTime
        self.preferredInputDeviceId = preferredInputDeviceId
        self.autoRecordEnabled = autoRecordEnabled
        self.autoConfirmEnabled = autoConfirmEnabled
        self.showConfirmSheet = showConfirmSheet
        self.isMuted = isMuted
    }

    // MARK: - Default Configuration

    /// Default settings matching app defaults
    static let `default` = QuizSettings(
        language: "en",
        audioMode: "media",
        numberOfQuestions: 10,
        category: nil,
        difficulty: "medium",
        autoAdvanceDelay: 8,
        answerTimeLimit: 30,
        thinkingTime: 60,
        preferredInputDeviceId: nil,
        autoRecordEnabled: true,
        autoConfirmEnabled: true,
        showConfirmSheet: true,
        isMuted: false
    )

    // MARK: - Backward-Compatible Decoding

    /// Custom decoder tolerates missing keys so new fields can be added without
    /// breaking previously-persisted settings. Also silently ignores removed
    /// keys like `voiceCommandsEnabled` / `bargeInEnabled` from older builds —
    /// Codable drops unrecognized keys automatically, no guard needed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        audioMode = try container.decode(String.self, forKey: .audioMode)
        numberOfQuestions = try container.decode(Int.self, forKey: .numberOfQuestions)
        category = try container.decodeIfPresent(String.self, forKey: .category)
        difficulty = try container.decode(String.self, forKey: .difficulty)
        autoAdvanceDelay = try container.decode(Int.self, forKey: .autoAdvanceDelay)
        answerTimeLimit = try container.decode(Int.self, forKey: .answerTimeLimit)
        thinkingTime = try container.decodeIfPresent(Int.self, forKey: .thinkingTime) ?? 60
        preferredInputDeviceId = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceId)
        autoRecordEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRecordEnabled) ?? true
        autoConfirmEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoConfirmEnabled) ?? true
        showConfirmSheet = try container.decodeIfPresent(Bool.self, forKey: .showConfirmSheet) ?? true
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    }

    // MARK: - Validation Helpers

    /// Valid question count options
    static let questionCountOptions = [5, 10, 15, 20]

    /// Valid difficulty options
    static let difficultyOptions = ["easy", "medium", "hard", "random"]

    /// Valid auto-advance delay options (seconds)
    static let autoAdvanceDelayOptions = [5, 8, 10, 15]

    /// Valid answer time limit options (seconds, 0 = Off)
    static let answerTimeLimitOptions = [0, 15, 20, 30, 45, 60]

    /// Valid thinking time options (seconds, 0 = immediate recording)
    static let thinkingTimeOptions = [0, 15, 30, 45, 60, 90, 120]

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
