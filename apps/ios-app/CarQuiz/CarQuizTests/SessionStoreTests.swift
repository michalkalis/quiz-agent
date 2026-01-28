//
//  SessionStoreTests.swift
//  CarQuizTests
//
//  Unit tests for SessionStore using isolated UserDefaults.
//

import Foundation
import Testing
@testable import CarQuiz

@Suite("SessionStore Tests")
struct SessionStoreTests {

    /// Creates a SessionStore backed by a unique UserDefaults suite.
    /// Each test gets a fresh, empty defaults domain.
    private func makeStore() -> (SessionStore, UserDefaults) {
        let suiteName = "test.SessionStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SessionStore(userDefaults: defaults)
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
