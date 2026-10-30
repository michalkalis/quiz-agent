//
//  Config.swift
//  Hangs
//
//  Application configuration and environment settings
//

import Foundation

nonisolated enum Config {
    /// Base URL for the Quiz Agent API
    ///
    /// Read from Info.plist which gets populated from xcconfig files based on build configuration
    static var apiBaseURL: String {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String else {
            fatalError("API_BASE_URL not found in Info.plist. Ensure xcconfig files are properly configured.")
        }
        return url
    }

    /// Base URL for the quiz-pack-api (custom-pack ordering, issue #95). Distinct
    /// host from `apiBaseURL` — populated from Info.plist via xcconfig.
    static var packApiBaseURL: String {
        guard let url = Bundle.main.object(forInfoDictionaryKey: "PACK_API_BASE_URL") as? String else {
            fatalError("PACK_API_BASE_URL not found in Info.plist. Ensure xcconfig files are properly configured.")
        }
        return url
    }

    /// Public legal pages on the brand site (apps/website, `LEGAL` in build.py),
    /// in the app's UI language: trubbo.app/privacy (en), /sk/privacy, /cs/privacy.
    /// The same URLs are printed into the App Store listing (fastlane/metadata).
    static var privacyPolicyURL: URL {
        legalPageURL("privacy")
    }

    static var termsOfUseURL: URL {
        legalPageURL("terms")
    }

    static func legalPageURL(
        _ page: String,
        languageCode: String = InterfaceLanguage.code
    ) -> URL {
        let prefix = ["sk", "cs"].contains(languageCode) ? "/\(languageCode)" : ""
        return URL(string: "https://trubbo.app\(prefix)/\(page)")!
    }

    /// API version prefix
    ///
    /// Read from Info.plist which gets populated from xcconfig files
    static var apiVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "API_VERSION") as? String else {
            return "/api/v1" // Fallback
        }
        return version
    }

    /// Full API base URL with version
    static var apiBaseURLWithVersion: String {
        return apiBaseURL + apiVersion
    }

    /// Current environment name (Local, Production, etc.)
    static var environmentName: String {
        guard let env = Bundle.main.object(forInfoDictionaryKey: "ENVIRONMENT_NAME") as? String else {
            return "Unknown"
        }
        return env
    }

    // MARK: - App Configuration

    /// Default number of questions per quiz
    static let defaultQuestions = 10

    /// Default quiz difficulty: a mix, each question's level picked by the
    /// server (#216, founder 2026-10-30).
    static let defaultDifficulty = "random"

    /// Session expiry time in minutes (should match backend TTL)
    static let sessionTTLMinutes = 30

    /// Audio download timeout in seconds
    static let audioDownloadTimeout: TimeInterval = 10.0

    /// Voice recording maximum duration in seconds
    static let maxRecordingDuration: TimeInterval = 30.0

    // MARK: - Settings Options

    /// Available question count options for quiz settings
    static let questionCountOptions = [5, 10, 15, 20]

    /// Available difficulty options for quiz settings
    static var difficultyOptions: [(String, String)] {
        [
            ("easy", String(localized: "Easy", bundle: .interface, locale: .interface, comment: "Quiz difficulty option")),
            ("medium", String(localized: "Medium", bundle: .interface, locale: .interface, comment: "Quiz difficulty option")),
            ("hard", String(localized: "Hard", bundle: .interface, locale: .interface, comment: "Quiz difficulty option")),
            ("random", String(localized: "Random", bundle: .interface, locale: .interface, comment: "Quiz difficulty option: pick difficulty at random")),
        ]
    }

    /// Available category options for quiz settings (nil = All Categories)
    /// Interest-based taxonomy (2026-08 revamp) — mirrors the backend
    /// `CATEGORY_TAXONOMY` in `apps/quiz-agent/app/api/admin.py`. Age is a
    /// separate axis (`ageAppropriateOptions`); fandom/themed content lives in
    /// packs, not here. Backend filters on whatever id is sent.
    static var categoryOptions: [(id: String?, display: String)] {
        [
            (nil, String(localized: "All Categories", bundle: .interface, locale: .interface, comment: "Quiz category option: no category filter")),
            ("science-nature", String(localized: "Science & Nature", bundle: .interface, locale: .interface, comment: "Quiz category option")),
            ("history", String(localized: "History", bundle: .interface, locale: .interface, comment: "Quiz category option")),
            ("geography-world", String(localized: "Geography & World", bundle: .interface, locale: .interface, comment: "Quiz category option")),
            ("movies-music", String(localized: "Movies & Music", bundle: .interface, locale: .interface, comment: "Quiz category option")),
            ("sports", String(localized: "Sports", bundle: .interface, locale: .interface, comment: "Quiz category option")),
            ("food-everyday", String(localized: "Food & Everyday Life", bundle: .interface, locale: .interface, comment: "Quiz category option")),
            ("entertainment", String(localized: "Entertainment", bundle: .interface, locale: .interface, comment: "Quiz category option")),
        ]
    }

    /// Human-readable (localized) name for a taxonomy category id; nil for
    /// anything else (#198: a raw id like "general" or "adults" must never
    /// reach the screen — the caller shows nothing instead).
    static func categoryDisplayName(for id: String) -> String? {
        categoryOptions.first { $0.id == id }?.display
    }

    /// Same names as `categoryOptions`, as resources so a screen can resolve
    /// them in the locale it is rendered in. `categoryOptions` freezes the
    /// process language at first access; a view that pins its own locale
    /// (the end-of-round label, snapshot hosts) would then mix two languages.
    private static let categoryResources: [String: LocalizedStringResource] = [
        "science-nature": "Science & Nature",
        "history": "History",
        "geography-world": "Geography & World",
        "movies-music": "Movies & Music",
        "sports": "Sports",
        "food-everyday": "Food & Everyday Life",
        "entertainment": "Entertainment",
    ]

    /// `categoryDisplayName(for:)` resolved in `locale` (the view's environment
    /// locale). nil for anything outside the taxonomy, as above.
    static func categoryDisplayName(for id: String, locale: Locale) -> String? {
        guard var resource = categoryResources[id] else { return nil }
        resource.locale = locale
        return String(localized: resource)
    }

    /// Available age-appropriate filter options (nil = no filter / show all)
    /// Values match `Question.age_appropriate` on the backend.
    static let ageAppropriateOptions: [(id: String?, display: String)] = [
        (nil, "Any age"),
        ("all", "Family-friendly"),
        ("8+", "8+"),
        ("12+", "12+"),
        ("16+", "16+"),
    ]

    /// Whether the Home "Image questions" toggle is shown (#96 P3). OFF until
    /// image question content ships (founder, 2026-07-12) — the setting and its
    /// wiring (`QuizSettings.includeImageQuestions`, honored in QuestionView)
    /// stay intact; only the toggle UI is hidden. Flip to `true` to re-expose.
    static let imageQuestionsToggleVisible = false

    /// HIDDEN dead-air cap for one recording (seconds). The driver never sees
    /// it: it only guarantees the mic closes when nothing is ever said and no
    /// VAD commit arrives. Once speech starts, the answer ends on the
    /// on-device VAD's silence, not here — which is why it can stay this long
    /// (raised from 4 s to 15 s for Phase 2 silence detection so a long spoken
    /// answer is never cut off mid-sentence).
    /// Lowered 15 → 8 s (founder 2026-10-10): in car noise the energy VAD
    /// takes road noise for speech and never ends, so 7 of 40 answers sat out
    /// the full 15 s while a real answer is ≤ 3 s of speech. Proper fix =
    /// #197.6 (silence detection tuned on recorded data).
    static let autoRecordingDuration: TimeInterval = 8.0

    /// VISIBLE "time to start speaking" countdown (seconds) — founder
    /// 2026-09-07 (#173). Showing the 15 s cap made the screen look frozen: the
    /// driver has finished speaking long before it, and re-record inherited the
    /// same number ("Nahrať znova has 14 s"). 5 s bounds only the START of
    /// speech (the pre-silence-detection value was 4 s); the first partial
    /// transcript / VAD speech event hides the countdown and the answer then
    /// runs on VAD under the hidden `autoRecordingDuration` cap. Expiring with
    /// no speech ends the recording exactly as the cap does — forced commit →
    /// empty transcript → confirmation sheet with an empty field (#171 B).
    static let speechStartWindow: TimeInterval = 5.0

    /// Delay after TTS finishes before auto-starting recording (milliseconds)
    static let autoRecordDelayMs: UInt64 = 500

    /// #208 (founder 2026-10-16): with read-aloud muted, or a question without
    /// audio, the think countdown stands still (full) for a silent reading pause
    /// first: question words / `silentReadingWordsPerSecond`, clamped to the
    /// min/max. Deterministic from the text, so the same question always gets
    /// the same pause.
    static let silentReadingWordsPerSecond: Double = 2.5
    static let silentReadingPauseMin: TimeInterval = 3
    static let silentReadingPauseMax: TimeInterval = 15

    /// Countdown duration for auto-confirm (also controls re-record window) in
    /// seconds. #171 Track F (founder 2026-09-05): 10 s read as "the app froze"
    /// on the TF round — the driver has already spoken and is waiting to hear
    /// the result. 5 s is still long enough to say "again" or tap Re-record.
    static let autoConfirmDelaySecs: Int = 5

    // MARK: - Dictation (feedback, rating, pack prompt)

    /// How often the dictation recorder hands its PCM chunks over (milliseconds).
    static let sttStreamingChunkIntervalMs: UInt64 = 250

    /// Hard cap on a single in-app feedback dictation (#109). ~120 s of 16 kHz
    /// 16-bit mono PCM ≈ 3.8 MB WAV, under the dictation endpoint's 5 MB limit.
    static let feedbackDictationCapSecs: TimeInterval = 120

    // MARK: - Voice Commands (#77)

    /// Founder-overridable build/settings flag (P4a): spoken "start" on QuestionView
    /// (`askingQuestion`, after TTS) opens the mic — the hands-free START recovery.
    /// Default ON. Setting this to `false` disables ONLY that wiring and leaves the
    /// rest of the command layer (repeat / skip / ok / again / next) intact. It does
    /// NOT auto-open the mic — the thinking-timer + mic-button flow is unchanged (P1).
    /// Copied into `VoiceCommandCoordinator.voiceStartOnQuestionEnabled` per instance
    /// (so tests can flip it without a global).
    static let voiceStartCommandEnabled: Bool = true

    /// Founder-overridable build/settings flag: arm the command listener on the idle
    /// Home screen so spoken "start" begins the quiz. Default ON. On-device English
    /// command recognition only — nothing leaves the device. Copied into
    /// `VoiceCommandCoordinator.voiceStartOnHomeEnabled` per instance.
    static let voiceHomeStartEnabled: Bool = true

    // MARK: - Freemium

    /// RevenueCat public Apple SDK key (project "CarQuiz", fe489552). Public by
    /// design — safe to embed in the client; entitlement is still resolved
    /// server-side via the backend's RevenueCat secret key + webhook mirror.
    static let revenueCatPublicSDKKey = "appl_zaNZviocTQkXpIoNzpqJehlnLwm"

    // MARK: - Sentry

    /// Sentry DSN for crash reporting
    ///
    /// Read from Info.plist which gets populated from xcconfig files based on build configuration.
    /// Empty string disables Sentry (e.g., for local development if not needed).
    static var sentryDSN: String {
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String, !dsn.isEmpty else {
            return "" // Sentry disabled when DSN not configured
        }
        return dsn
    }

    // MARK: - Debug Settings

    /// Enable verbose logging in debug builds
    /// Note: nonisolated needed to access from actors (NetworkService, etc.)
    nonisolated static let verboseLogging: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    #if DEBUG
        /// Simulate slow network for testing
        static let simulateSlowNetwork = false
    #endif
}

// MARK: - Environment Helper

extension Config {
    /// Check if running in DEBUG mode
    static var isDebug: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    /// Check if running on simulator
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }
}
