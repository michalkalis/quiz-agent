//
//  PersistenceStoreTests.swift
//  CarQuizTests
//
//  Unit tests for PersistenceStore using isolated UserDefaults.
//

import Foundation
import Testing
@testable import CarQuiz

// MARK: - Session Tests

@Suite("PersistenceStore Session Tests")
struct PersistenceStoreSessionTests {

    /// Creates a PersistenceStore backed by a unique UserDefaults suite.
    /// Each test gets a fresh, empty defaults domain.
    private func makeStore() -> (PersistenceStore, UserDefaults) {
        let suiteName = "test.PersistenceStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = PersistenceStore(userDefaults: defaults)
        return (store, defaults)
    }

    // MARK: - Session ID Round-Trip

    @Test("saveSession stores and currentSessionId retrieves the ID")
    func saveAndRetrieveSessionId() {
        let (store, _) = makeStore()

        store.saveSession(id: "session_abc")

        #expect(store.currentSessionId == "session_abc")
    }

    @Test("clearSession removes the stored session ID")
    func clearSessionRemovesId() {
        let (store, _) = makeStore()

        store.saveSession(id: "session_abc")
        store.clearSession()

        #expect(store.currentSessionId == nil)
    }

    @Test("currentSessionId is nil when no session has been saved")
    func currentSessionIdNilByDefault() {
        let (store, _) = makeStore()

        #expect(store.currentSessionId == nil)
    }

    // MARK: - Settings Round-Trip

    @Test("saveSettings and loadSettings round-trip correctly")
    func settingsRoundTrip() {
        let (store, _) = makeStore()

        let settings = QuizSettings(
            language: "sk",
            audioMode: "media",
            numberOfQuestions: 20,
            category: "adults",
            difficulty: "hard",
            autoAdvanceDelay: 5,
            answerTimeLimit: 45,
            preferredInputDeviceId: "device_123"
        )

        store.saveSettings(settings)
        let loaded = store.loadSettings()

        #expect(loaded == settings)
    }

    @Test("loadSettings returns .default when no saved data exists")
    func loadSettingsReturnsDefaultWhenEmpty() {
        let (store, _) = makeStore()

        let loaded = store.loadSettings()

        #expect(loaded == QuizSettings.default)
    }

    @Test("loadSettings returns .default when saved data is corrupt JSON")
    func loadSettingsReturnsDefaultOnCorruptData() {
        let (store, defaults) = makeStore()

        // Write invalid JSON data to the settings key
        let corruptData = Data("not valid json".utf8)
        defaults.set(corruptData, forKey: "quiz_settings")

        let loaded = store.loadSettings()

        #expect(loaded == QuizSettings.default)
    }

    // MARK: - Legacy Keys Ignored

    @Test("loadSettings ignores stale legacy individual keys")
    func loadSettingsIgnoresLegacyKeys() {
        let (store, defaults) = makeStore()

        // Legacy keys that existed before the unified QuizSettings JSON.
        // After migration code removal, these should be ignored.
        defaults.set("sk", forKey: "preferred_language")
        defaults.set("media", forKey: "preferred_audio_mode")

        let loaded = store.loadSettings()

        // No migration — should return .default regardless of legacy keys
        #expect(loaded == QuizSettings.default)
    }
}

// MARK: - Question History Tests

@Suite("PersistenceStore Question History Tests")
struct PersistenceStoreQuestionHistoryTests {

    /// Creates a PersistenceStore backed by a unique UserDefaults suite.
    private func makeStore() -> PersistenceStore {
        let suiteName = "test.PersistenceStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return PersistenceStore(userDefaults: defaults)
    }

    // MARK: - Basic Operations

    @Test("addQuestionId persists and retrieves the ID")
    func addAndRetrieve() throws {
        let store = makeStore()

        try store.addQuestionId("q_001")

        #expect(store.askedQuestionIds == ["q_001"])
    }

    @Test("adding same ID twice does not create duplicates")
    func deduplication() throws {
        let store = makeStore()

        try store.addQuestionId("q_001")
        try store.addQuestionId("q_001")

        #expect(store.askedQuestionIds == ["q_001"])
    }

    @Test("clearHistory removes all entries")
    func clearHistory() throws {
        let store = makeStore()

        try store.addQuestionId("q_001")
        try store.addQuestionId("q_002")
        store.clearHistory()

        #expect(store.askedQuestionIds.isEmpty)
    }

    @Test("getExclusionList returns same as askedQuestionIds")
    func exclusionListMatchesAskedIds() throws {
        let store = makeStore()

        try store.addQuestionId("q_001")
        try store.addQuestionId("q_002")

        #expect(store.getExclusionList() == store.askedQuestionIds)
    }

    @Test("empty history returns empty array")
    func emptyHistoryReturnsEmptyArray() {
        let store = makeStore()

        #expect(store.askedQuestionIds == [])
        #expect(store.getExclusionList() == [])
    }

    // MARK: - Capacity

    @Test("isAtCapacity returns true at 500 questions")
    func isAtCapacityAt500() throws {
        let store = makeStore()

        for i in 0..<500 {
            try store.addQuestionId("q_\(i)")
        }

        #expect(store.isAtCapacity == true)
    }

    @Test("addQuestionId throws capacityReached at limit")
    func addQuestionIdThrowsAtCapacity() throws {
        let store = makeStore()

        for i in 0..<500 {
            try store.addQuestionId("q_\(i)")
        }

        #expect(throws: QuestionHistoryError.capacityReached) {
            try store.addQuestionId("q_overflow")
        }
        // Count should remain at 500
        #expect(store.askedQuestionIds.count == 500)
    }

    // MARK: - Batch Operations

    @Test("addQuestionIds batch-adds with deduplication")
    func batchAddWithDedup() throws {
        let store = makeStore()

        try store.addQuestionId("q_001")
        try store.addQuestionIds(["q_001", "q_002", "q_003"])

        #expect(store.askedQuestionIds == ["q_001", "q_002", "q_003"])
    }

    @Test("addQuestionIds throws when batch would exceed capacity")
    func batchAddThrowsWhenExceedingCapacity() throws {
        let store = makeStore()

        // Fill to 499
        for i in 0..<499 {
            try store.addQuestionId("q_\(i)")
        }

        // Adding 2 new IDs (dedup-aware) would push to 501
        #expect(throws: QuestionHistoryError.capacityReached) {
            try store.addQuestionIds(["q_new_1", "q_new_2"])
        }
        // Count should remain at 499 (batch is all-or-nothing)
        #expect(store.askedQuestionIds.count == 499)
    }
}
