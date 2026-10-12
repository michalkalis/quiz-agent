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
    /// #200: per-pack played ids, keyed by pack id.
    var playedPackQuestions: [String: [String]] = [:]

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

    func addQuestionId(_ id: String) {
        guard !askedQuestionIds.contains(id) else { return }
        askedQuestionIds.append(id)
        if askedQuestionIds.count > PersistenceStore.historyWindow {
            askedQuestionIds.removeFirst(askedQuestionIds.count - PersistenceStore.historyWindow)
        }
    }

    func clearHistory() {
        askedQuestionIds.removeAll()
    }

    func getExclusionList() -> [String] {
        return askedQuestionIds
    }

    // MARK: - Pack progress (#200)

    func playedPackQuestionIds(packId: String) -> [String] {
        playedPackQuestions[packId] ?? []
    }

    func markPackQuestionPlayed(_ questionId: String, packId: String) {
        guard !playedPackQuestionIds(packId: packId).contains(questionId) else { return }
        playedPackQuestions[packId, default: []].append(questionId)
    }

    func clearPackProgress(packId: String) {
        playedPackQuestions[packId] = nil
    }

    // MARK: - Quiz Stats

    var stats = QuizStats.empty

    func loadStats() -> QuizStats {
        stats
    }

    func saveStats(_ stats: QuizStats) {
        self.stats = stats
    }

    // MARK: - Contextual sign-in prompt (#58 §9)

    var signInPromptShownCount: Int = 0

    func incrementSignInPromptShownCount() {
        signInPromptShownCount += 1
    }
}
#endif
