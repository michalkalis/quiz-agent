//
//  PersistenceStore.swift
//  CarQuiz
//
//  Unified UserDefaults persistence for session management and question history.
//

import Foundation
import os

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
    // MARK: - Device Identity

    /// Stable device identifier for usage tracking (persists across sessions)
    var deviceId: String { get }

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

    // MARK: - Quiz Stats

    /// Load saved quiz statistics
    func loadStats() -> QuizStats

    /// Save quiz statistics
    func saveStats(_ stats: QuizStats)
}

/// Unified UserDefaults-based persistence storage
final class PersistenceStore: PersistenceStoreProtocol {
    // UserDefaults is not Sendable in Swift 6, but it's thread-safe
    // We use nonisolated(unsafe) to acknowledge this
    nonisolated(unsafe) private let userDefaults: UserDefaults

    // Keys
    private let deviceIdKey = "device_id"
    private let onboardingKey = "has_completed_onboarding"
    private let sessionIdKey = "current_session_id"
    private let settingsKey = "quiz_settings"
    private let historyKey = "asked_question_history"
    private let maxCapacity = 500
    private let statsKey = "quiz_stats"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Device Identity

    var deviceId: String {
        if let existing = userDefaults.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = "dev_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))"
        userDefaults.set(newId, forKey: deviceIdKey)
        return newId
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

        Logger.persistence.debug("📦 PersistenceStore: Saved session ID: \(id, privacy: .public)")
    }

    func clearSession() {
        userDefaults.removeObject(forKey: sessionIdKey)

        Logger.persistence.debug("📦 PersistenceStore: Cleared session ID")
    }

    // MARK: - Settings

    func saveSettings(_ settings: QuizSettings) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: settingsKey)

            Logger.persistence.debug("📦 PersistenceStore: Saved settings: \(String(describing: settings), privacy: .public)")
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to encode settings: \(error, privacy: .public)")
        }
    }

    func loadSettings() -> QuizSettings {
        // Try to load saved settings
        guard let data = userDefaults.data(forKey: settingsKey) else {
            Logger.persistence.debug("📦 PersistenceStore: No saved settings found, using default")
            return QuizSettings.default
        }

        do {
            let decoder = JSONDecoder()
            let settings = try decoder.decode(QuizSettings.self, from: data)

            Logger.persistence.debug("📦 PersistenceStore: Loaded settings: \(String(describing: settings), privacy: .public)")

            return settings
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to decode settings: \(error, privacy: .public), using default")
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
            Logger.persistence.debug("📦 PersistenceStore: Question \(id, privacy: .public) already in history, skipping")
            return
        }

        // Check capacity before adding
        if history.count >= maxCapacity {
            Logger.persistence.warning("❌ PersistenceStore: Capacity reached (\(self.maxCapacity, privacy: .public) questions)")
            throw QuestionHistoryError.capacityReached
        }

        history.append(id)
        userDefaults.set(history, forKey: historyKey)

        Logger.persistence.debug("📦 PersistenceStore: Saved question \(id, privacy: .public) (total: \(history.count, privacy: .public)/\(self.maxCapacity, privacy: .public))")
    }

    func addQuestionIds(_ ids: [String]) throws {
        var history = askedQuestionIds

        // Filter out duplicates
        let newIds = ids.filter { !history.contains($0) }

        // Check capacity before adding
        if history.count + newIds.count > maxCapacity {
            Logger.persistence.warning("❌ PersistenceStore: Adding \(newIds.count, privacy: .public) questions would exceed capacity")
            throw QuestionHistoryError.capacityReached
        }

        history.append(contentsOf: newIds)
        userDefaults.set(history, forKey: historyKey)

        Logger.persistence.debug("📦 PersistenceStore: Saved \(newIds.count, privacy: .public) questions (total: \(history.count, privacy: .public)/\(self.maxCapacity, privacy: .public))")
    }

    func clearHistory() {
        userDefaults.removeObject(forKey: historyKey)

        Logger.persistence.info("📦 PersistenceStore: Cleared all history")
    }

    func getExclusionList() -> [String] {
        let history = askedQuestionIds
        Logger.persistence.debug("📦 PersistenceStore: Retrieved \(history.count, privacy: .public) excluded question IDs")
        return history
    }

    // MARK: - Quiz Stats

    func loadStats() -> QuizStats {
        guard let data = userDefaults.data(forKey: statsKey) else {
            return QuizStats.empty
        }
        do {
            return try JSONDecoder().decode(QuizStats.self, from: data)
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to decode stats: \(error, privacy: .public), using empty")
            return QuizStats.empty
        }
    }

    func saveStats(_ stats: QuizStats) {
        do {
            let data = try JSONEncoder().encode(stats)
            userDefaults.set(data, forKey: statsKey)
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to encode stats: \(error, privacy: .public)")
        }
    }
}

// MARK: - Mock for Testing and Previews

#if DEBUG
final class MockPersistenceStore: PersistenceStoreProtocol {
    // Device identity
    nonisolated(unsafe) var deviceId: String = "dev_mock_test_1234"

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

    // MARK: - Quiz Stats

    nonisolated(unsafe) var stats = QuizStats.empty

    func loadStats() -> QuizStats {
        stats
    }

    func saveStats(_ stats: QuizStats) {
        self.stats = stats
    }
}
#endif
