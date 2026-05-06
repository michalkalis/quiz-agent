//
//  MockPersistenceStore.swift
//  Hangs
//
//  Mock PersistenceStore for DEBUG builds (SwiftUI previews, UI-test mode).
//

import Foundation
import os

#if DEBUG
// @MainActor inherited from PersistenceStoreProtocol — all properties are safely main-thread-only
@MainActor
final class MockPersistenceStore: PersistenceStoreProtocol {
    // Device identity
    var deviceId: String = "dev_mock_test_1234"

    // Onboarding state
    var hasCompletedOnboarding: Bool = true

    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    // Session state
    var currentSessionId: String?

    // Settings state
    var savedSettings: QuizSettings?
    var saveSettingsCallCount: Int = 0

    // Question history state
    var askedQuestionIds: [String] = []
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

    var stats = QuizStats.empty

    func loadStats() -> QuizStats {
        stats
    }

    func saveStats(_ stats: QuizStats) {
        self.stats = stats
    }
}
#endif
