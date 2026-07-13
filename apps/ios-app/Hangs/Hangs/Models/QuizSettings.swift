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

    /// Category filter — multi-select (#82 item 4, founder decision 7).
    /// Empty = all categories. See `Config.categoryOptions` for valid ids.
    var categories: [String]

    /// Optional age-appropriate filter. nil = no filter, otherwise one of "all" | "8+" | "12+" | "16+".
    /// Matches `Question.age_appropriate` on the backend.
    var ageAppropriate: String?

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

    /// Whether recording start/stop earcons play (#68). Only gates the mic-live /
    /// got-it cues — command-ack and skip earcons stay on (driving-safety feedback).
    var recordingSoundsEnabled: Bool

    /// Whether image questions may be served (#68). Default OFF — images are
    /// fun but unsuitable while driving (founder decision 6, 2026-07-05).
    var includeImageQuestions: Bool

    /// Master switch for the hands-free English voice-command listener (#77 /
    /// #96 P2). Default ON. When OFF, the screen-scoped command window never arms
    /// (`QuizViewModel.currentCommandScreen` returns nil) and the on-screen
    /// listening indicator is suppressed — buttons remain the untouched fallback.
    var voiceCommandsEnabled: Bool

    // MARK: - Memberwise Init

    init(
        language: String,
        audioMode: String,
        numberOfQuestions: Int,
        categories: [String] = [],
        difficulty: String,
        autoAdvanceDelay: Int,
        answerTimeLimit: Int,
        thinkingTime: Int = 10,
        preferredInputDeviceId: String?,
        autoRecordEnabled: Bool = true,
        autoConfirmEnabled: Bool = true,
        showConfirmSheet: Bool = true,
        isMuted: Bool = false,
        ageAppropriate: String? = nil,
        recordingSoundsEnabled: Bool = true,
        includeImageQuestions: Bool = false,
        voiceCommandsEnabled: Bool = true
    ) {
        self.language = language
        self.audioMode = audioMode
        self.numberOfQuestions = numberOfQuestions
        self.categories = categories
        self.difficulty = difficulty
        self.autoAdvanceDelay = autoAdvanceDelay
        self.answerTimeLimit = answerTimeLimit
        self.thinkingTime = thinkingTime
        self.preferredInputDeviceId = preferredInputDeviceId
        self.autoRecordEnabled = autoRecordEnabled
        self.autoConfirmEnabled = autoConfirmEnabled
        self.showConfirmSheet = showConfirmSheet
        self.isMuted = isMuted
        self.ageAppropriate = ageAppropriate
        self.recordingSoundsEnabled = recordingSoundsEnabled
        self.includeImageQuestions = includeImageQuestions
        self.voiceCommandsEnabled = voiceCommandsEnabled
    }

    // MARK: - Default Configuration

    /// Default settings matching app defaults
    static let `default` = QuizSettings(
        language: "en",
        audioMode: "media",
        numberOfQuestions: 10,
        categories: [],
        difficulty: "medium",
        autoAdvanceDelay: 8,
        answerTimeLimit: 30,
        thinkingTime: 10,
        preferredInputDeviceId: nil,
        autoRecordEnabled: true,
        autoConfirmEnabled: true,
        showConfirmSheet: true,
        isMuted: false,
        recordingSoundsEnabled: true,
        includeImageQuestions: false,
        voiceCommandsEnabled: true
    )

    // MARK: - Backward-Compatible Decoding

    /// Custom decoder tolerates missing keys so new fields can be added without
    /// breaking previously-persisted settings. Also silently ignores removed
    /// keys like `bargeInEnabled` from older builds — Codable drops unrecognized
    /// keys automatically, no guard needed. (`voiceCommandsEnabled` was dropped
    /// once and is re-introduced in #96 P2 as the master command toggle.)
    /// Pre-multi-select persisted blobs carry a single `category` string.
    private enum LegacyKeys: String, CodingKey {
        case category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        audioMode = try container.decode(String.self, forKey: .audioMode)
        numberOfQuestions = try container.decode(Int.self, forKey: .numberOfQuestions)
        if let list = try container.decodeIfPresent([String].self, forKey: .categories) {
            categories = list
        } else {
            // Migrate the pre-#82 single-select blob: one category → one-element list.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            categories = (try legacy.decodeIfPresent(String.self, forKey: .category)).map { [$0] } ?? []
        }
        difficulty = try container.decode(String.self, forKey: .difficulty)
        autoAdvanceDelay = try container.decode(Int.self, forKey: .autoAdvanceDelay)
        answerTimeLimit = try container.decode(Int.self, forKey: .answerTimeLimit)
        thinkingTime = try container.decodeIfPresent(Int.self, forKey: .thinkingTime) ?? 10
        preferredInputDeviceId = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceId)
        autoRecordEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRecordEnabled) ?? true
        autoConfirmEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoConfirmEnabled) ?? true
        showConfirmSheet = try container.decodeIfPresent(Bool.self, forKey: .showConfirmSheet) ?? true
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        ageAppropriate = try container.decodeIfPresent(String.self, forKey: .ageAppropriate)
        recordingSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .recordingSoundsEnabled) ?? true
        includeImageQuestions = try container.decodeIfPresent(Bool.self, forKey: .includeImageQuestions) ?? false
        voiceCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceCommandsEnabled) ?? true
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
    static let thinkingTimeOptions = [0, 10, 15, 30, 45, 60, 90, 120]

    /// Valid category options (nil means "All Categories"). Mirrors `Config.categoryOptions`.
    static let categoryOptions: [String?] = [
        nil, "general", "adults", "kids",
        "wizarding-world", "superheroes", "disney",
        "football", "sports-mix"
    ]

    /// Valid age-appropriate options (nil means no filter). Mirrors `Config.ageAppropriateOptions`.
    static let ageAppropriateOptions: [String?] = [nil, "all", "8+", "12+", "16+"]

    /// Display name for the active category selection (empty = "All Categories",
    /// one = its name, several = a count). Derives from `Config.categoryOptions`,
    /// the single source of id→display pairs, so each label lives in exactly one
    /// place for localization (#56).
    func categoryDisplayName() -> String {
        switch categories.count {
        case 0:
            return Config.categoryOptions.first { $0.id == nil }?.display ?? ""
        case 1:
            return Config.categoryOptions.first { $0.id == categories[0] }?.display ?? String(localized: "Unknown", comment: "Fallback category display name when the category id is unrecognized")
        default:
            return String(localized: "\(categories.count) selected", comment: "Home category picker value when several categories are selected; placeholder is the count")
        }
    }

    /// Display name for the active age-appropriate filter.
    func ageAppropriateDisplayName() -> String {
        switch ageAppropriate {
        case nil: return "Any age"
        case "all": return "Family-friendly"
        case "8+": return "8+"
        case "12+": return "12+"
        case "16+": return "16+"
        default: return "Unknown"
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
        categories: ["adults"],
        difficulty: "hard",
        autoAdvanceDelay: 5,
        answerTimeLimit: 45,
        preferredInputDeviceId: nil
    )
}
#endif
