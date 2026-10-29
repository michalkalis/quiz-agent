//
//  MockPlayerStatsService.swift
//  Hangs
//
//  #213: stat cards and recaps for tests, previews and the UI-test mock graph.
//

import Foundation

#if DEBUG
    final class MockPlayerStatsService: PlayerStatsServiceProtocol, @unchecked Sendable {
        /// Answered in order; the last one repeats.
        var results: [Result<PlayerStats, NetworkError>]
        var recapResults: [Result<[PlayerRecap], NetworkError>]
        private(set) var fetchCount = 0
        private(set) var recapFetchCount = 0
        private(set) var seenIDs: [String] = []

        init(
            results: [Result<PlayerStats, NetworkError>] = [.success(.mockSeasoned)],
            recaps: [Result<[PlayerRecap], NetworkError>] = [.success([])]
        ) {
            self.results = results
            recapResults = recaps
        }

        func fetchPlayerStats() async throws -> PlayerStats {
            let result = results[min(fetchCount, results.count - 1)]
            fetchCount += 1
            return try result.get()
        }

        func fetchRecaps() async throws -> [PlayerRecap] {
            let result = recapResults[min(recapFetchCount, recapResults.count - 1)]
            recapFetchCount += 1
            return try result.get()
        }

        func markRecapSeen(id: String) async throws {
            seenIDs.append(id)
        }
    }

    extension PlayerStats {
        /// A player well past the first recap: most cards open, two still locked.
        static let mockSeasoned = PlayerStats(
            cards: [
                StatCard(kind: "totals", progress: .init(current: 0, target: 0, unit: "answers"), content: .totals(answers: 312, minutes: 200)),
                StatCard(kind: "best_category", progress: .init(current: 3, target: 3, unit: "categories"), content: .bestCategory(category: "geography-world", accuracy: 82)),
                StatCard(kind: "weakest_category", progress: .init(current: 3, target: 3, unit: "categories"), content: .weakestCategory(category: "sports", accuracy: 41)),
                StatCard(kind: "where", progress: .init(current: 5, target: 5, unit: "games"), content: .whereYouPlay(place: "car", share: 64)),
                StatCard(kind: "when", progress: .init(current: 5, target: 5, unit: "games"), content: .whenYouPlay(partOfDay: "evening", weekday: "sunday")),
                StatCard(kind: "typical_game", progress: .init(current: 5, target: 5, unit: "games"), content: .typicalQuiz(minutes: 6.5, answers: 10)),
                StatCard(kind: "improvement", progress: .init(current: 150, target: 150, unit: "answers"), content: .improvement(deltaPoints: 12, direction: "up")),
                StatCard(kind: "best_streak", progress: .init(current: 1, target: 1, unit: "games"), content: .bestStreak(length: 9)),
                StatCard(kind: "hard_questions", progress: .init(current: 6, target: 10, unit: "answers"), content: nil),
                StatCard(kind: "mcq_vs_open", progress: .init(current: 10, target: 10, unit: "answers"), content: .choiceVsOwnAnswer(choiceAccuracy: 78, ownAccuracy: 64, better: "mcq")),
                StatCard(kind: "fastest_slowest", progress: .init(current: 1, target: 2, unit: "categories"), content: nil),
            ],
            firstRecapProgress: FirstRecapProgress(answers: 312, answersTarget: 60, days: 14, daysTarget: 3)
        )

        /// A new player on the way to the first recap.
        static let mockNewPlayer = PlayerStats(
            cards: [
                StatCard(kind: "totals", progress: .init(current: 0, target: 0, unit: "answers"), content: .totals(answers: 37, minutes: 25)),
                StatCard(kind: "best_category", progress: .init(current: 1, target: 3, unit: "categories"), content: nil),
                StatCard(kind: "where", progress: .init(current: 2, target: 5, unit: "games"), content: nil),
                StatCard(kind: "when", progress: .init(current: 1, target: 3, unit: "days"), content: nil),
                StatCard(kind: "best_streak", progress: .init(current: 1, target: 1, unit: "games"), content: .bestStreak(length: 5)),
            ],
            firstRecapProgress: FirstRecapProgress(answers: 37, answersTarget: 60, days: 2, daysTarget: 3)
        )
    }

    extension PlayerRecap {
        /// An October recap the player has not opened yet: the seasoned
        /// player's open cards, a road tripper.
        static let mockOctober = PlayerRecap(
            id: "6f1c2a7e-0000-4000-8000-000000000010",
            kind: .month,
            periodStart: "2026-10-01",
            seen: false,
            cards: PlayerStats.mockSeasoned.cards.filter { !$0.isLocked },
            playerType: "road_tripper"
        )
    }
#endif
