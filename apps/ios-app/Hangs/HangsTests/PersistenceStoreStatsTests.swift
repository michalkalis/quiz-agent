//
//  PersistenceStoreStatsTests.swift
//  HangsTests
//
//  QuizStats persistence round-trip + corruption fallback tests.
//  IsolatedDefaults helper is defined in PersistenceStoreTests.swift.
//

import Foundation
import Testing
@testable import Hangs

// MARK: - Stats Tests

@Suite("PersistenceStore Stats Tests")
@MainActor
struct PersistenceStoreStatsTests {

    private let statsKey = "quiz_stats"

    /// Creates a PersistenceStore backed by a unique, auto-cleaned UserDefaults suite.
    private func makeStore() -> (PersistenceStore, IsolatedDefaults) {
        let isolated = IsolatedDefaults()
        return (isolated.makeStore(), isolated)
    }

    // MARK: - Default

    @Test("loadStats returns .empty when no data has been saved")
    func loadStatsReturnsEmptyByDefault() {
        let (store, isolated) = makeStore()
        _ = isolated

        #expect(store.loadStats() == QuizStats.empty)
    }

    // MARK: - Round-Trip

    @Test("saveStats then loadStats round-trips all fields")
    func saveAndLoadRoundTrip() {
        let (store, isolated) = makeStore()
        _ = isolated

        let saved = QuizStats(
            currentStreak: 5,
            bestStreak: 10,
            totalCorrect: 42,
            totalAnswered: 100,
            totalQuizzes: 7
        )

        store.saveStats(saved)
        let loaded = store.loadStats()

        #expect(loaded == saved)
    }

    @Test("loadStats returns the most recently saved value")
    func subsequentSaveOverwritesPrevious() {
        let (store, isolated) = makeStore()
        _ = isolated

        let first = QuizStats(
            currentStreak: 1,
            bestStreak: 3,
            totalCorrect: 10,
            totalAnswered: 20,
            totalQuizzes: 2
        )
        let second = QuizStats(
            currentStreak: 5,
            bestStreak: 8,
            totalCorrect: 50,
            totalAnswered: 80,
            totalQuizzes: 9
        )

        store.saveStats(first)
        store.saveStats(second)

        #expect(store.loadStats() == second)
    }

    // MARK: - Corruption Fallback

    @Test("loadStats falls back to .empty when stored data is corrupt JSON")
    func loadStatsFallsBackOnCorruptData() {
        let (store, isolated) = makeStore()

        isolated.defaults.set(Data("not valid json at all!".utf8), forKey: statsKey)

        #expect(store.loadStats() == QuizStats.empty)
    }

    @Test("loadStats falls back to .empty when stored data is wrong-shape JSON")
    func loadStatsFallsBackOnWrongShapeJSON() {
        let (store, isolated) = makeStore()

        let wrongShape = try! JSONSerialization.data(withJSONObject: ["foo": "bar"])
        isolated.defaults.set(wrongShape, forKey: statsKey)

        #expect(store.loadStats() == QuizStats.empty)
    }

    // MARK: - Key Verification

    @Test("saveStats encodes to the configured statsKey")
    func saveStatsWritesToCorrectKey() throws {
        let (store, isolated) = makeStore()

        let saved = QuizStats(
            currentStreak: 3,
            bestStreak: 7,
            totalCorrect: 21,
            totalAnswered: 30,
            totalQuizzes: 4
        )
        store.saveStats(saved)

        // Read raw data directly from UserDefaults to confirm the correct key is used
        let rawData = try #require(isolated.defaults.data(forKey: statsKey))
        let decoded = try JSONDecoder().decode(QuizStats.self, from: rawData)

        #expect(decoded == saved)
    }
}
