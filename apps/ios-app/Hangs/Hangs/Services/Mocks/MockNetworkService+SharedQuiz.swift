//
//  MockNetworkService+SharedQuiz.swift
//  Hangs
//
//  #232 shared quiz on the mock: the three endpoints the app calls.
//

import Foundation

#if DEBUG
    extension MockNetworkService {
        func createSharedQuiz(sessionId: String?, packId: String?, displayName: String?) async throws -> SharedQuizCreated {
            createSharedQuizCalls.append((sessionId, packId, displayName))
            try await simulateNetwork(.createSharedQuiz)
            guard let stubbedShareCreated else { throw NetworkError.sharedQuizUnavailable(.notFound) }
            return stubbedShareCreated
        }

        func startSharedQuiz(token: String, displayName: String?) async throws -> SharedQuizStart {
            startSharedQuizCalls.append((token, displayName))
            try await simulateNetwork(.startSharedQuiz)
            if let startSharedQuizError { throw startSharedQuizError }
            if let stubbedShareStart { return stubbedShareStart }
            guard let session = mockSession else { throw NetworkError.invalidResponse }
            return SharedQuizStart(kind: "round", session: session, alreadyPlayed: false)
        }

        func sharedQuizResults(token _: String) async throws -> SharedQuizResults {
            sharedQuizResultsCallCount += 1
            try await simulateNetwork(.sharedQuizResults)
            guard let stubbedShareResults else { throw NetworkError.sharedQuizUnavailable(.notFound) }
            return stubbedShareResults
        }
    }
#endif
