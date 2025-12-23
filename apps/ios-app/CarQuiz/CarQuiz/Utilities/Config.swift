//
//  Config.swift
//  CarQuiz
//
//  Application configuration and environment settings
//

import Foundation

enum Config {
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
