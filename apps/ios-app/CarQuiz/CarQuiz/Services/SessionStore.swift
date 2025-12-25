//
//  SessionStore.swift
//  CarQuiz
//
//  UserDefaults persistence for session management
//

import Foundation

/// Protocol for session persistence
protocol SessionStoreProtocol: Sendable {
    var currentSessionId: String? { get }
    var preferredLanguage: String? { get }
    func saveSession(id: String)
    func saveLanguage(_ languageCode: String)
    func clearSession()
}

/// Simple UserDefaults-based session storage
final class SessionStore: SessionStoreProtocol {
    // UserDefaults is not Sendable in Swift 6, but it's thread-safe
    // We use nonisolated(unsafe) to acknowledge this
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let sessionIdKey = "current_session_id"
    private let languageKey = "preferred_language"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Get the currently stored session ID
    var currentSessionId: String? {
        userDefaults.string(forKey: sessionIdKey)
    }

    /// Get the user's preferred language
    var preferredLanguage: String? {
        userDefaults.string(forKey: languageKey)
    }

    /// Save a session ID for later resumption
    func saveSession(id: String) {
        userDefaults.set(id, forKey: sessionIdKey)

        if Config.verboseLogging {
            print("📦 SessionStore: Saved session ID: \(id)")
        }
    }

    /// Save the user's preferred language
    func saveLanguage(_ languageCode: String) {
        userDefaults.set(languageCode, forKey: languageKey)

        if Config.verboseLogging {
            print("📦 SessionStore: Saved language: \(languageCode)")
        }
    }

    /// Clear the stored session ID
    /// Note: Language preference is NOT cleared - it persists across sessions
    func clearSession() {
        userDefaults.removeObject(forKey: sessionIdKey)

        if Config.verboseLogging {
            print("📦 SessionStore: Cleared session ID")
        }
    }
}

// MARK: - Mock for Testing

#if DEBUG
final class MockSessionStore: SessionStoreProtocol {
    // Mock store for testing - marked as unsafe since it's mutable
    // In production, use SessionStore which uses thread-safe UserDefaults
    nonisolated(unsafe) var currentSessionId: String?
    nonisolated(unsafe) var preferredLanguage: String?

    func saveSession(id: String) {
        currentSessionId = id
    }

    func saveLanguage(_ languageCode: String) {
        preferredLanguage = languageCode
    }

    func clearSession() {
        currentSessionId = nil
    }
}
#endif
