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
    func saveSession(id: String)
    func clearSession()
}

/// Simple UserDefaults-based session storage
final class SessionStore: SessionStoreProtocol {
    // UserDefaults is not Sendable in Swift 6, but it's thread-safe
    // We use nonisolated(unsafe) to acknowledge this
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let sessionIdKey = "current_session_id"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Get the currently stored session ID
    var currentSessionId: String? {
        userDefaults.string(forKey: sessionIdKey)
    }

    /// Save a session ID for later resumption
    func saveSession(id: String) {
        userDefaults.set(id, forKey: sessionIdKey)

        if Config.verboseLogging {
            print("📦 SessionStore: Saved session ID: \(id)")
        }
    }

    /// Clear the stored session ID
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

    func saveSession(id: String) {
        currentSessionId = id
    }

    func clearSession() {
        currentSessionId = nil
    }
}
#endif
