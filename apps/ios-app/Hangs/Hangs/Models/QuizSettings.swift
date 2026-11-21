//
//  QuizSettings.swift
//  Hangs
//
//  Centralized quiz configuration model
//

import Foundation

/// #132 Track E (founder pick 2026-07-29): when the driver learns the correct
/// answers — after every question (today's behavior, the default) or all at
/// once in the end-of-set recap. Supersedes launch decision D4.
enum AnswerRevealMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case perQuestion = "per_question"
    case endOfSet = "end_of_set"

    var id: String { rawValue }

    /// Menu/row display string (localized).
    var displayName: String {
        switch self {
        case .perQuestion:
            return String(localized: "After each question", bundle: .interface, locale: .interface, comment: "Answer reveal setting: today's per-question result screen")
        case .endOfSet:
            return String(localized: "At the end of the set", bundle: .interface, locale: .interface, comment: "Answer reveal setting: deferred reveal, one recap after the last question")
        }
    }
}

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

    /// Which round-length default the saved value was made under: none = 10
    /// (every build up to 90), 2 = 8 (founder, TestFlight build 90 feedback).
    /// See `init(from:)`.
    private var numberOfQuestionsDefaultVersion = Self.currentQuestionCountDefaultVersion

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

    /// Retired with the "Answer time limit" setting (#200 — auto-record is
    /// always on, so the think window is the only answer window). Nothing
    /// reads it; it is still WRITTEN because a 1.0 build's decoder requires
    /// the key, and a tester going back to a 1.0 TestFlight build would
    /// otherwise lose every setting.
    private var answerTimeLimit = 30

    /// Thinking time in seconds before auto-recording starts (0 = immediate 500ms delay)
    var thinkingTime: Int

    /// Which think-time default the saved value was made under: none = 10 s
    /// (every build up to 89), 2 = 0 s (build 90, #240.9), 3 = 10 s again.
    /// See `init(from:)`.
    private var thinkingTimeDefaultVersion = Self.currentThinkingTimeDefaultVersion

    /// Preferred input device UID (nil = automatic selection)
    var preferredInputDeviceId: String?

    /// Whether to auto-confirm transcribed answers after a 2s countdown
    /// When enabled, skips the confirmation modal — say "re-record" to cancel
    var autoConfirmEnabled: Bool

    /// Whether to show the answer confirmation sheet before submitting
    /// When disabled, answers are submitted immediately after transcription
    var showConfirmSheet: Bool

    /// Whether TTS audio playback is muted (questions still display visually)
    var isMuted: Bool

    /// Whether the mic-live tone plays (#68). #188 G6: it is the only earcon with
    /// a tone; off → haptic only. Every other cue is haptic-only regardless.
    var recordingSoundsEnabled: Bool

    /// Whether image questions may be served (#68). Default OFF — images are
    /// fun but unsuitable while driving (founder decision 6, 2026-07-05).
    var includeImageQuestions: Bool

    /// Whether questions only people from one country understand may be served
    /// (#206, e.g. Bratislava public transport). Default ON (founder
    /// 2026-10-15); OFF sends `skip_local_questions` with the session.
    var includeLocalQuestions: Bool

    /// Master switch for the hands-free English voice-command listener (#77 /
    /// #96 P2). Default ON. When OFF, the screen-scoped command window never arms
    /// (`QuizViewModel.currentCommandScreen` returns nil) and the on-screen
    /// listening indicator is suppressed — buttons remain the untouched fallback.
    var voiceCommandsEnabled: Bool

    /// #132 Track E: when correct answers are revealed. `.perQuestion` is
    /// today's flow (result screen after every answer); `.endOfSet` skips the
    /// per-question result entirely and reveals everything in the recap.
    var answerRevealMode: AnswerRevealMode

    /// Whether the "say …" words are shown under the listening bar. nil = the
    /// default, which is ON; a value is the driver's explicit Settings choice.
    ///
    /// #179 D1 (founder 2026-09-15) REVERSES #174's five-quiz expiry: the words
    /// silently switched themselves off after five completed quizzes, leaving the
    /// founder — well past five — with a bare "LISTENING FOR COMMANDS" that named
    /// nothing he could say. Voice commands are the product, not training wheels;
    /// they stay visible until the driver turns them off.
    var voiceHintsEnabled: Bool?

    /// #224.8 "Quick quiz" (canvas D2, founder 2026-11-03). OFF = today's flow.
    /// ON: skipping a question goes straight to the next one, with a brief
    /// note of the right answer instead of a result screen.
    var quickGame: Bool

    /// The one rule for whether the command words are shown: an explicit Settings
    /// choice wins, otherwise they are shown.
    static func voiceHintsVisible(override: Bool?) -> Bool {
        override ?? true
    }

    // MARK: - Memberwise Init

    init(
        language: String,
        audioMode: String,
        numberOfQuestions: Int,
        categories: [String] = [],
        difficulty: String,
        autoAdvanceDelay: Int,
        thinkingTime: Int = Self.defaultThinkingTime,
        preferredInputDeviceId: String?,
        autoConfirmEnabled: Bool = true,
        showConfirmSheet: Bool = true,
        isMuted: Bool = false,
        ageAppropriate: String? = nil,
        recordingSoundsEnabled: Bool = true,
        includeImageQuestions: Bool = false,
        includeLocalQuestions: Bool = true,
        voiceCommandsEnabled: Bool = true,
        answerRevealMode reveal: AnswerRevealMode = .perQuestion,
        voiceHintsEnabled: Bool? = nil,
        quickGame: Bool = false
    ) {
        self.language = language
        self.audioMode = audioMode
        self.numberOfQuestions = numberOfQuestions
        self.categories = categories
        self.difficulty = difficulty
        self.autoAdvanceDelay = autoAdvanceDelay
        self.thinkingTime = thinkingTime
        self.preferredInputDeviceId = preferredInputDeviceId
        self.autoConfirmEnabled = autoConfirmEnabled
        self.showConfirmSheet = showConfirmSheet
        self.isMuted = isMuted
        self.ageAppropriate = ageAppropriate
        self.recordingSoundsEnabled = recordingSoundsEnabled
        self.includeImageQuestions = includeImageQuestions
        self.includeLocalQuestions = includeLocalQuestions
        self.voiceCommandsEnabled = voiceCommandsEnabled
        answerRevealMode = reveal
        self.voiceHintsEnabled = voiceHintsEnabled
        self.quickGame = quickGame
    }

    // MARK: - Default Configuration

    /// Nothing saved yet: the quiz — and with it the whole app (founder
    /// 2026-10-30, `InterfaceLanguage`) — starts in the phone's language when
    /// it is offered. Otherwise a Slovak phone would open an English app.
    static func firstLaunch(phoneLanguage: String?) -> QuizSettings {
        var settings = QuizSettings.default
        if let phoneLanguage {
            settings.language = Language.selectable(phoneLanguage).id
        }
        return settings
    }

    /// Default settings matching app defaults
    static let `default` = QuizSettings(
        language: "en",
        audioMode: "media",
        numberOfQuestions: Self.defaultNumberOfQuestions,
        categories: [],
        difficulty: Config.defaultDifficulty,
        autoAdvanceDelay: 8,
        thinkingTime: Self.defaultThinkingTime,
        preferredInputDeviceId: nil,
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
    /// keys like `bargeInEnabled` or `autoRecordEnabled` (#200) from older
    /// builds — Codable drops unrecognized keys automatically, no guard needed. (`voiceCommandsEnabled` was dropped
    /// once and is re-introduced in #96 P2 as the master command toggle.)
    /// Pre-multi-select persisted blobs carry a single `category` string.
    private enum LegacyKeys: String, CodingKey {
        case category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A persisted language that is no longer offered (#168 DD14 hid it, or
        // its corpus was pulled) degrades to the default — mirrors the category
        // filter below: a stale value would otherwise be sent to the backend.
        language = Language.selectable(try container.decode(String.self, forKey: .language)).id
        audioMode = try container.decode(String.self, forKey: .audioMode)
        numberOfQuestions = Self.migratedQuestionCount(
            try container.decode(Int.self, forKey: .numberOfQuestions),
            defaultVersion: try container.decodeIfPresent(Int.self, forKey: .numberOfQuestionsDefaultVersion) ?? 1
        )
        if let list = try container.decodeIfPresent([String].self, forKey: .categories) {
            categories = list
        } else {
            // Migrate the pre-#82 single-select blob: one category → one-element list.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            categories = try (legacy.decodeIfPresent(String.self, forKey: .category)).map { [$0] } ?? []
        }
        // Drop ids retired by taxonomy changes (2026-08 revamp): a stale
        // selection like "disney" would silently filter every quiz to empty.
        // Dropping degrades to "All Categories", which always has content.
        categories = categories.filter { Self.categoryOptions.contains($0) }
        difficulty = try container.decode(String.self, forKey: .difficulty)
        autoAdvanceDelay = try container.decode(Int.self, forKey: .autoAdvanceDelay)
        thinkingTime = try container.decodeIfPresent(Int.self, forKey: .thinkingTime) ?? Self.defaultThinkingTime
        // Build 90 (#240.9) made 0 s the default and rewrote every saved 10 s
        // to 0. The founder rejected that flow after testing it (2026-11-21),
        // so a 0 saved under build 90's default goes back to 10 s. A 0 the
        // player picked on purpose cannot be told apart from build 90's
        // default; build 90 was TestFlight only, and 0 stays one tap away.
        let defaultVersion = try container.decodeIfPresent(Int.self, forKey: .thinkingTimeDefaultVersion) ?? 1
        if defaultVersion == Self.immediateMicDefaultVersion, thinkingTime == Self.immediateMicDefaultThinkingTime {
            thinkingTime = Self.defaultThinkingTime
        }
        preferredInputDeviceId = try container.decodeIfPresent(String.self, forKey: .preferredInputDeviceId)
        autoConfirmEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoConfirmEnabled) ?? true
        showConfirmSheet = try container.decodeIfPresent(Bool.self, forKey: .showConfirmSheet) ?? true
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        ageAppropriate = try container.decodeIfPresent(String.self, forKey: .ageAppropriate)
        recordingSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .recordingSoundsEnabled) ?? true
        includeImageQuestions = try container.decodeIfPresent(Bool.self, forKey: .includeImageQuestions) ?? false
        includeLocalQuestions = try container.decodeIfPresent(Bool.self, forKey: .includeLocalQuestions) ?? true
        voiceCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceCommandsEnabled) ?? true
        // #132 E: pre-existing blobs (and unknown future raw values) fall back
        // to today's per-question flow — the founder-picked default.
        answerRevealMode = (try? container.decodeIfPresent(AnswerRevealMode.self, forKey: .answerRevealMode)).flatMap { $0 } ?? .perQuestion
        // #174: absent = automatic (first quizzes only) — never a persisted "on".
        voiceHintsEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceHintsEnabled)
        // #224.8: absent = off, today's flow.
        quickGame = try container.decodeIfPresent(Bool.self, forKey: .quickGame) ?? false
    }

    // MARK: - Validation Helpers

    /// Valid question count options (founder, TestFlight build 90: 10 was
    /// too many, so 8 is the default and 20 left the list).
    static let questionCountOptions = [5, 8, 10, 15]
    static let defaultNumberOfQuestions = 8
    /// Every build up to 90 saved 10 as its default, with no version.
    static let legacyDefaultNumberOfQuestions = 10
    static let currentQuestionCountDefaultVersion = 2

    /// Runs once, on a blob saved before this version. A 10 there is the old
    /// default, not a choice: the saved data cannot tell a player who picked
    /// 10 from one who never touched it, and most never did, so it becomes the
    /// new default (10 stays one tap away). Any other saved value is the
    /// player's choice and stays; one the list no longer offers (20) becomes
    /// the nearest that it does.
    static func migratedQuestionCount(_ saved: Int, defaultVersion: Int) -> Int {
        guard defaultVersion < currentQuestionCountDefaultVersion else { return saved }
        if saved == legacyDefaultNumberOfQuestions { return defaultNumberOfQuestions }
        if questionCountOptions.contains(saved) { return saved }
        return questionCountOptions.min { abs($0 - saved) < abs($1 - saved) } ?? defaultNumberOfQuestions
    }

    /// Valid difficulty options
    static let difficultyOptions = ["easy", "medium", "hard", "random"]

    /// Valid auto-advance delay options (seconds)
    static let autoAdvanceDelayOptions = [5, 8, 10, 15]

    /// Think time before the mic opens on its own (#68, driving-critical).
    static let defaultThinkingTime = 10
    /// Build 90's default (#240.9, rejected) and the version it saved with.
    static let immediateMicDefaultThinkingTime = 0
    static let immediateMicDefaultVersion = 2
    static let currentThinkingTimeDefaultVersion = 3

    /// Valid thinking time options (seconds, 0 = immediate recording)
    static let thinkingTimeOptions = [0, 10, 15, 30, 45, 60, 90, 120]

    /// Valid category options (nil means "All Categories"). Mirrors `Config.categoryOptions`.
    static let categoryOptions: [String?] = [
        nil, "science-nature", "history", "geography-world",
        "movies-music", "sports", "food-everyday", "entertainment",
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
            return Config.categoryOptions.first { $0.id == categories[0] }?.display ?? String(localized: "Unknown", bundle: .interface, locale: .interface, comment: "Fallback category display name when the category id is unrecognized")
        default:
            return String(localized: "\(categories.count) selected", bundle: .interface, locale: .interface, comment: "Home category picker value when several categories are selected; placeholder is the count")
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
    /// #130: capitalizing the raw id ("medium" → "Medium") left this value English
    /// in a Slovak interface. Resolve through the same localized option list the
    /// picker uses; fall back to the capitalized id for unknown ids.
    func difficultyDisplayName() -> String {
        Config.difficultyOptions.first { $0.0 == difficulty }?.1
            ?? (difficulty.prefix(1).uppercased() + difficulty.dropFirst())
    }
}

// MARK: - Preview Helpers

#if DEBUG
    extension QuizSettings {
        static let previewCustom = QuizSettings(
            language: "sk",
            audioMode: "media",
            numberOfQuestions: 20,
            categories: ["science-nature"],
            difficulty: "hard",
            autoAdvanceDelay: 5,
            preferredInputDeviceId: nil
        )
    }
#endif
