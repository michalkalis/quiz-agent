//
//  PersistenceStore.swift
//  CarQuiz
//
//  Unified UserDefaults persistence for session management and question history.
//

import Foundation

/// Error types for question history operations
enum QuestionHistoryError: Error {
    case capacityReached

    var localizedDescription: String {
        switch self {
        case .capacityReached:
            return "Question history has reached its maximum capacity of 500 questions."
        }
    }
}

/// Protocol for unified persistence (session + settings + question history)
protocol PersistenceStoreProtocol: Sendable {
    // MARK: - Onboarding

    /// Whether the user has completed the onboarding flow
    var hasCompletedOnboarding: Bool { get }

    /// Mark onboarding as completed
    func completeOnboarding()

    // MARK: - Session

    /// Get the currently stored session ID
    var currentSessionId: String? { get }

    /// Save a session ID for later resumption
    func saveSession(id: String)

    /// Clear the stored session ID
    func clearSession()

    // MARK: - Settings

    /// Save comprehensive quiz settings
    func saveSettings(_ settings: QuizSettings)

    /// Load saved quiz settings (returns default if not found)
    func loadSettings() -> QuizSettings

    // MARK: - Question History

    /// All question IDs that have been asked
    var askedQuestionIds: [String] { get }

    /// Whether the history has reached maximum capacity (500 questions)
    var isAtCapacity: Bool { get }

    /// Add a question ID to the history
    /// - Parameter id: Question ID to add
    /// - Throws: `QuestionHistoryError.capacityReached` if capacity exceeded
    func addQuestionId(_ id: String) throws

    /// Add multiple question IDs to the history
    /// - Parameter ids: Array of question IDs to add
    /// - Throws: `QuestionHistoryError.capacityReached` if capacity exceeded
    func addQuestionIds(_ ids: [String]) throws

    /// Clear all question history
    func clearHistory()

    /// Get list of question IDs for exclusion (alias for askedQuestionIds)
    /// - Returns: Array of question IDs to exclude
    func getExclusionList() -> [String]
}

/// Unified UserDefaults-based persistence storage
final class PersistenceStore: PersistenceStoreProtocol {
    // UserDefaults is not Sendable in Swift 6, but it's thread-safe
    // We use nonisolated(unsafe) to acknowledge this
    nonisolated(unsafe) private let userDefaults: UserDefaults

    // Keys
    private let onboardingKey = "has_completed_onboarding"
    private let sessionIdKey = "current_session_id"
    private let settingsKey = "quiz_settings"
    private let historyKey = "asked_question_history"
    private let maxCapacity = 500

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        userDefaults.bool(forKey: onboardingKey)
    }

    func completeOnboarding() {
        userDefaults.set(true, forKey: onboardingKey)
    }

    // MARK: - Session

    var currentSessionId: String? {
        userDefaults.string(forKey: sessionIdKey)
    }

    func saveSession(id: String) {
        userDefaults.set(id, forKey: sessionIdKey)

        if Config.verboseLogging {
            print("📦 PersistenceStore: Saved session ID: \(id)")
        }
    }

    func clearSession() {
        userDefaults.removeObject(forKey: sessionIdKey)

        if Config.verboseLogging {
            print("📦 PersistenceStore: Cleared session ID")
        }
    }

    // MARK: - Settings

    func saveSettings(_ settings: QuizSettings) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: settingsKey)

            if Config.verboseLogging {
                print("📦 PersistenceStore: Saved settings: \(settings)")
            }
        } catch {
            if Config.verboseLogging {
                print("❌ PersistenceStore: Failed to encode settings: \(error)")
            }
        }
    }

    func loadSettings() -> QuizSettings {
        // Try to load saved settings
        guard let data = userDefaults.data(forKey: settingsKey) else {
            if Config.verboseLogging {
                print("📦 PersistenceStore: No saved settings found, using default")
            }
            return QuizSettings.default
        }

        do {
            let decoder = JSONDecoder()
            let settings = try decoder.decode(QuizSettings.self, from: data)

            if Config.verboseLogging {
                print("📦 PersistenceStore: Loaded settings: \(settings)")
            }

            return settings
        } catch {
            if Config.verboseLogging {
                print("❌ PersistenceStore: Failed to decode settings: \(error), using default")
            }
            return QuizSettings.default
        }
    }

    // MARK: - Question History

    var askedQuestionIds: [String] {
        userDefaults.stringArray(forKey: historyKey) ?? []
    }

    var isAtCapacity: Bool {
        return askedQuestionIds.count >= maxCapacity
    }

    func addQuestionId(_ id: String) throws {
        var history = askedQuestionIds

        // Skip if already in history (deduplication)
        guard !history.contains(id) else {
            if Config.verboseLogging {
                print("📦 PersistenceStore: Question \(id) already in history, skipping")
            }
            return
        }

        // Check capacity before adding
        if history.count >= maxCapacity {
            if Config.verboseLogging {
                print("❌ PersistenceStore: Capacity reached (\(maxCapacity) questions)")
            }
            throw QuestionHistoryError.capacityReached
        }

        history.append(id)
        userDefaults.set(history, forKey: historyKey)

        if Config.verboseLogging {
            print("📦 PersistenceStore: Saved question \(id) (total: \(history.count)/\(maxCapacity))")
        }
    }

    func addQuestionIds(_ ids: [String]) throws {
        var history = askedQuestionIds

        // Filter out duplicates
        let newIds = ids.filter { !history.contains($0) }

        // Check capacity before adding
        if history.count + newIds.count > maxCapacity {
            if Config.verboseLogging {
                print("❌ PersistenceStore: Adding \(newIds.count) questions would exceed capacity")
            }
            throw QuestionHistoryError.capacityReached
        }

        history.append(contentsOf: newIds)
        userDefaults.set(history, forKey: historyKey)

        if Config.verboseLogging {
            print("📦 PersistenceStore: Saved \(newIds.count) questions (total: \(history.count)/\(maxCapacity))")
        }
    }

    func clearHistory() {
        userDefaults.removeObject(forKey: historyKey)

        if Config.verboseLogging {
            print("📦 PersistenceStore: Cleared all history")
        }
    }

    func getExclusionList() -> [String] {
        let history = askedQuestionIds
        if Config.verboseLogging {
            print("📦 PersistenceStore: Retrieved \(history.count) excluded question IDs")
        }
        return history
    }
}

// MARK: - Mock for Testing and Previews

#if DEBUG
final class MockPersistenceStore: PersistenceStoreProtocol {
    // Onboarding state
    nonisolated(unsafe) var hasCompletedOnboarding: Bool = true

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    // Session state
    nonisolated(unsafe) var currentSessionId: String?

    // Settings state
    nonisolated(unsafe) var savedSettings: QuizSettings?
    nonisolated(unsafe) var saveSettingsCallCount: Int = 0

    // Question history state
    nonisolated(unsafe) var askedQuestionIds: [String] = []
    private let maxCapacity = 500

    // MARK: - Session

    func saveSession(id: String) {
        currentSessionId = id
    }

    func clearSession() {
        currentSessionId = nil
    }

    // MARK: - Settings

    func saveSettings(_ settings: QuizSettings) {
        savedSettings = settings
        saveSettingsCallCount += 1
    }

    func loadSettings() -> QuizSettings {
        savedSettings ?? QuizSettings.default
    }

    // MARK: - Question History

    var isAtCapacity: Bool {
        return askedQuestionIds.count >= maxCapacity
    }

    func addQuestionId(_ id: String) throws {
        guard !askedQuestionIds.contains(id) else { return }

        if askedQuestionIds.count >= maxCapacity {
            throw QuestionHistoryError.capacityReached
        }

        askedQuestionIds.append(id)
    }

    func addQuestionIds(_ ids: [String]) throws {
        let newIds = ids.filter { !askedQuestionIds.contains($0) }

        if askedQuestionIds.count + newIds.count > maxCapacity {
            throw QuestionHistoryError.capacityReached
        }

        askedQuestionIds.append(contentsOf: newIds)
    }

    func clearHistory() {
        askedQuestionIds.removeAll()
    }

    func getExclusionList() -> [String] {
        return askedQuestionIds
    }
}
#endif
