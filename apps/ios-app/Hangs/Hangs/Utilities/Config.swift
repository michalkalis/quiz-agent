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

    /// Default quiz difficulty
    static let defaultDifficulty = "medium"

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
    static let difficultyOptions = [
        ("easy", String(localized: "Easy", comment: "Quiz difficulty option")),
        ("medium", String(localized: "Medium", comment: "Quiz difficulty option")),
        ("hard", String(localized: "Hard", comment: "Quiz difficulty option")),
        ("random", String(localized: "Random", comment: "Quiz difficulty option: pick difficulty at random"))
    ]

    /// Available category options for quiz settings (nil = All Categories)
    /// Order: All → core → themed packs. Backend filters on whatever id is sent.
    static let categoryOptions: [(id: String?, display: String)] = [
        (nil, String(localized: "All Categories", comment: "Quiz category option: no category filter")),
        ("general", String(localized: "General", comment: "Quiz category option")),
        ("adults", String(localized: "Adults", comment: "Quiz category option: adult-oriented questions")),
        ("kids", String(localized: "Kids", comment: "Quiz category option: kid-friendly questions")),
        ("wizarding-world", String(localized: "Wizarding World", comment: "Quiz category option (themed pack; brand-adjacent — see 56.4 Don't-translate pass)")),
        ("superheroes", String(localized: "Superheroes", comment: "Quiz category option (themed pack)")),
        ("disney", String(localized: "Disney", comment: "Quiz category option (themed pack; brand name — see 56.4 Don't-translate pass)")),
        ("football", String(localized: "Football", comment: "Quiz category option (themed pack)")),
        ("sports-mix", String(localized: "Sports Mix", comment: "Quiz category option (themed pack)"))
    ]

    /// Available age-appropriate filter options (nil = no filter / show all)
    /// Values match `Question.age_appropriate` on the backend.
    static let ageAppropriateOptions: [(id: String?, display: String)] = [
        (nil, "Any age"),
        ("all", "Family-friendly"),
        ("8+", "8+"),
        ("12+", "12+"),
        ("16+", "16+")
    ]

    /// Whether the Home "Image questions" toggle is shown (#96 P3). OFF until
    /// image question content ships (founder, 2026-07-12) — the setting and its
    /// wiring (`QuizSettings.includeImageQuestions`, honored in QuestionView)
    /// stay intact; only the toggle UI is hidden. Flip to `true` to re-expose.
    static let imageQuestionsToggleVisible = false

    /// Duration for auto-stop recording — hard safety limit (seconds)
    /// Increased from 4s to 15s for Phase 2 silence detection (users may speak longer answers)
    static let autoRecordingDuration: TimeInterval = 15.0

    /// How long the streaming path waits after a forced STT commit before
    /// treating the silence as a transcription failure (#54 task 54.4)
    static let sttCommitWatchdogSecs: TimeInterval = 5.0

    /// Delay after TTS finishes before auto-starting recording (milliseconds)
    static let autoRecordDelayMs: UInt64 = 500

    /// Countdown duration for auto-confirm (also controls re-record window) in seconds
    static let autoConfirmDelaySecs: Int = 10

    // MARK: - ElevenLabs Streaming STT

    /// Feature flag: use ElevenLabs Scribe v2 Realtime for quiz answers instead of Whisper.
    /// Provides live word-by-word transcript display while the user speaks.
    /// On any setup/connection failure, recording falls back to Whisper batch.
    static let useElevenLabsSTT: Bool = true

    /// ElevenLabs Scribe v2 Realtime model ID
    static let elevenLabsModel: String = "scribe_v2_realtime"

    /// Audio format for ElevenLabs WebSocket (raw PCM, 16kHz, 16-bit, mono)
    static let elevenLabsAudioFormat: String = "pcm_16000"

    /// Interval for streaming audio chunks to ElevenLabs WebSocket (milliseconds)
    static let sttStreamingChunkIntervalMs: UInt64 = 250

    /// Hard cap on a single in-app feedback dictation (#109). ~120 s of 16 kHz
    /// 16-bit mono PCM ≈ 3.8 MB WAV, under the backend's 10 MB audio guideline.
    static let feedbackDictationCapSecs: TimeInterval = 120

    /// VAD silence threshold — ElevenLabs commits transcript after this many seconds of silence.
    /// Centralised in `VADTuning` (77.11); forwarded here for back-compat.
    static let elevenLabsVadSilenceThresholdSecs: Double = VADTuning.elevenLabsVadSilenceThresholdSecs

    // MARK: - Voice Commands (#77)

    /// Founder-overridable build/settings flag (P4a): spoken "start" on QuestionView
    /// (`askingQuestion`, after TTS) opens the mic — the hands-free START recovery.
    /// Default ON. Setting this to `false` disables ONLY that wiring and leaves the
    /// rest of the command layer (repeat / skip / ok / again / next) intact. It does
    /// NOT auto-open the mic — the thinking-timer + mic-button flow is unchanged (P1).
    /// Copied into `QuizViewModel.voiceStartOnQuestionEnabled` per instance (so tests
    /// can flip it without a global).
    static let voiceStartCommandEnabled: Bool = true

    /// Founder-overridable build/settings flag: arm the command listener on the idle
    /// Home screen so spoken "start" begins the quiz. Default ON. On-device English
    /// command recognition only — nothing leaves the device. Copied into
    /// `QuizViewModel.voiceStartOnHomeEnabled` per instance.
    static let voiceHomeStartEnabled: Bool = true

    // MARK: - Freemium

    /// StoreKit product identifier for unlimited access
    static let unlimitedProductId = "com.carquiz.unlimited"

    /// RevenueCat public Apple SDK key (project "CarQuiz", fe489552). Public by
    /// design — safe to embed in the client; entitlement is still resolved
    /// server-side via the backend's RevenueCat secret key + webhook mirror.
    static let revenueCatPublicSDKKey = "appl_zaNZviocTQkXpIoNzpqJehlnLwm"

    /// Free tier daily question limit (display only — enforced by backend)
    static let freeDailyQuestionLimit = 20

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
