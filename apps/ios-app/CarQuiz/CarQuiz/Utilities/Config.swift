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
    /// - Simulator: Points to localhost backend (for local development)
    /// - Physical Device: Points to deployed backend URL on Fly.io
    static var apiBaseURL: String {
        #if targetEnvironment(simulator)
        // iOS Simulator - backend running locally on port 8002
        // Note: Use "localhost" for iOS Simulator, not "127.0.0.1"
        return "http://localhost:8002"
        #else
        // Physical device - deployed on Fly.io
        return "https://quiz-agent-api.fly.dev"
        #endif
    }

    /// API version prefix
    static let apiVersion = "/api/v1"

    /// Full API base URL with version
    static var apiBaseURLWithVersion: String {
        return apiBaseURL + apiVersion
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
    nonisolated(unsafe) static let verboseLogging: Bool = {
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
