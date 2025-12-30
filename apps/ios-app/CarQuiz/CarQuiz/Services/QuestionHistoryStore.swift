//
//  QuestionHistoryStore.swift
//  CarQuiz
//
//  Created by Claude Code on 2025-12-30.
//  Manages persistent storage of question history to prevent repeating questions across sessions.
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

/// Protocol for question history storage
protocol QuestionHistoryStoreProtocol: Sendable {
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

/// Persistent storage for question history using UserDefaults
final class QuestionHistoryStore: QuestionHistoryStoreProtocol {
    nonisolated(unsafe) private let userDefaults: UserDefaults
    private let historyKey = "asked_question_history"
    private let maxCapacity = 500

    /// Initialize with custom UserDefaults (useful for testing)
    /// - Parameter userDefaults: UserDefaults instance to use
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

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
                print("📦 QuestionHistoryStore: Question \(id) already in history, skipping")
            }
            return
        }

        // Check capacity before adding
        if history.count >= maxCapacity {
            if Config.verboseLogging {
                print("❌ QuestionHistoryStore: Capacity reached (\(maxCapacity) questions)")
            }
            throw QuestionHistoryError.capacityReached
        }

        history.append(id)
        userDefaults.set(history, forKey: historyKey)

        if Config.verboseLogging {
            print("📦 QuestionHistoryStore: Saved question \(id) (total: \(history.count)/\(maxCapacity))")
        }
    }

    func addQuestionIds(_ ids: [String]) throws {
        var history = askedQuestionIds

        // Filter out duplicates
        let newIds = ids.filter { !history.contains($0) }

        // Check capacity before adding
        if history.count + newIds.count > maxCapacity {
            if Config.verboseLogging {
                print("❌ QuestionHistoryStore: Adding \(newIds.count) questions would exceed capacity")
            }
            throw QuestionHistoryError.capacityReached
        }

        history.append(contentsOf: newIds)
        userDefaults.set(history, forKey: historyKey)

        if Config.verboseLogging {
            print("📦 QuestionHistoryStore: Saved \(newIds.count) questions (total: \(history.count)/\(maxCapacity))")
        }
    }

    func clearHistory() {
        userDefaults.removeObject(forKey: historyKey)

        if Config.verboseLogging {
            print("📦 QuestionHistoryStore: Cleared all history")
        }
    }

    func getExclusionList() -> [String] {
        let history = askedQuestionIds
        if Config.verboseLogging {
            print("📦 QuestionHistoryStore: Retrieved \(history.count) excluded question IDs")
        }
        return history
    }
}

// MARK: - Mock for Testing and Previews
#if DEBUG
final class MockQuestionHistoryStore: QuestionHistoryStoreProtocol {
    nonisolated(unsafe) var askedQuestionIds: [String] = []
    private let maxCapacity = 500

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
