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
    var preferredAudioMode: String? { get }
    func saveSession(id: String)
    func saveLanguage(_ languageCode: String)
    func saveAudioMode(_ modeId: String)
    func clearSession()
    func saveSettings(_ settings: QuizSettings)
    func loadSettings() -> QuizSettings
}

/// Simple UserDefaults-based session storage
final class SessionStore: SessionStoreProtocol {
    // UserDefaults is not Sendable in Swift 6, but it's thread-safe
    // We use nonisolated(unsafe) to acknowledge this
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let sessionIdKey = "current_session_id"
    private let languageKey = "preferred_language"
    private let audioModeKey = "preferred_audio_mode"
    private let settingsKey = "quiz_settings"

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

    /// Get the user's preferred audio mode
    var preferredAudioMode: String? {
        userDefaults.string(forKey: audioModeKey)
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

    /// Save the user's preferred audio mode
    func saveAudioMode(_ modeId: String) {
        userDefaults.set(modeId, forKey: audioModeKey)

        if Config.verboseLogging {
            print("📦 SessionStore: Saved audio mode: \(modeId)")
        }
    }

    /// Clear the stored session ID
    /// Note: Language and audio mode preferences are NOT cleared - they persist across sessions
    func clearSession() {
        userDefaults.removeObject(forKey: sessionIdKey)

        if Config.verboseLogging {
            print("📦 SessionStore: Cleared session ID")
        }
    }

    /// Save comprehensive quiz settings
    func saveSettings(_ settings: QuizSettings) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: settingsKey)

            if Config.verboseLogging {
                print("📦 SessionStore: Saved settings: \(settings)")
            }
        } catch {
            if Config.verboseLogging {
                print("❌ SessionStore: Failed to encode settings: \(error)")
            }
        }
    }

    /// Load saved quiz settings (returns default if not found)
    func loadSettings() -> QuizSettings {
        // Try to load saved settings
        guard let data = userDefaults.data(forKey: settingsKey) else {
            // No saved settings, migrate from individual keys if they exist
            if let language = preferredLanguage, let audioMode = preferredAudioMode {
                let migratedSettings = QuizSettings(
                    language: language,
                    audioMode: audioMode,
                    numberOfQuestions: QuizSettings.default.numberOfQuestions,
                    category: QuizSettings.default.category,
                    difficulty: QuizSettings.default.difficulty,
                    autoAdvanceDelay: QuizSettings.default.autoAdvanceDelay
                )

                // Save migrated settings for future
                saveSettings(migratedSettings)

                if Config.verboseLogging {
                    print("📦 SessionStore: Migrated settings from individual keys")
                }

                return migratedSettings
            }

            if Config.verboseLogging {
                print("📦 SessionStore: No saved settings found, using default")
            }
            return QuizSettings.default
        }

        do {
            let decoder = JSONDecoder()
            let settings = try decoder.decode(QuizSettings.self, from: data)

            if Config.verboseLogging {
                print("📦 SessionStore: Loaded settings: \(settings)")
            }

            return settings
        } catch {
            if Config.verboseLogging {
                print("❌ SessionStore: Failed to decode settings: \(error), using default")
            }
            return QuizSettings.default
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
    nonisolated(unsafe) var preferredAudioMode: String?
    nonisolated(unsafe) var savedSettings: QuizSettings?

    func saveSession(id: String) {
        currentSessionId = id
    }

    func saveLanguage(_ languageCode: String) {
        preferredLanguage = languageCode
    }

    func saveAudioMode(_ modeId: String) {
        preferredAudioMode = modeId
    }

    func clearSession() {
        currentSessionId = nil
    }

    func saveSettings(_ settings: QuizSettings) {
        savedSettings = settings
    }

    func loadSettings() -> QuizSettings {
        savedSettings ?? QuizSettings.default
    }
}
#endif
