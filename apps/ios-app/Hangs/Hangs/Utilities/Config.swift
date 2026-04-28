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
        ("easy", "Easy"),
        ("medium", "Medium"),
        ("hard", "Hard"),
        ("random", "Random")
    ]

    /// Available category options for quiz settings (nil = All Categories)
    static let categoryOptions: [(id: String?, display: String)] = [
        (nil, "All Categories"),
        ("adults", "Adults"),
        ("general", "General")
    ]

    /// Available auto-advance delay options (in seconds)
    static let autoAdvanceDelayOptions = [5, 8, 10, 15]

    /// Available answer time limit options (in seconds, 0 = Off)
    static let answerTimeLimitOptions = [0, 15, 20, 30, 45, 60]

    /// Available thinking time options (in seconds, 0 = immediate recording)
    static let thinkingTimeOptions: [Int] = [0, 15, 30, 45, 60, 90, 120]

    /// Duration for auto-stop recording — hard safety limit (seconds)
    /// Increased from 4s to 15s for Phase 2 silence detection (users may speak longer answers)
    static let autoRecordingDuration: TimeInterval = 15.0

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

    /// VAD silence threshold — ElevenLabs commits transcript after this many seconds of silence
    static let elevenLabsVadSilenceThresholdSecs: Double = 1.5

    // MARK: - Freemium

    /// StoreKit product identifier for unlimited access
    static let unlimitedProductId = "com.carquiz.unlimited"

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
