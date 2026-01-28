//
//  QuestionHistoryStoreTests.swift
//  CarQuizTests
//
//  Unit tests for QuestionHistoryStore using isolated UserDefaults.
//

import Foundation
import Testing
@testable import CarQuiz

@Suite("QuestionHistoryStore Tests")
struct QuestionHistoryStoreTests {

    /// Creates a QuestionHistoryStore backed by a unique UserDefaults suite.
    private func makeStore() -> QuestionHistoryStore {
        let suiteName = "test.QuestionHistoryStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return QuestionHistoryStore(userDefaults: defaults)
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
