//
//  UserFacingTimeout.swift
//  Hangs
//
//  Shared by the voice-answer submit (#131 Track A) and the MCQ tap submit
//  (#178): every answer submission gets the same bounded wait, so a wedged
//  request surfaces as a retryable "Request timed out" instead of a spinner
//  that never ends (founder TF 2026-09-13, MCQ 4/10 stuck in .processing).
//

import Foundation

/// Runs an async operation with a timeout, throwing `URLError(.timedOut)` if
/// exceeded. #131 Track A: a real `URLError` (not a private marker type) so
/// `AppErrorModel.from` can map it to the accurate "Request timed out" copy
/// instead of the generic submission fallback.
func withUserFacingTimeout<T: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            throw URLError(.timedOut)
        }

        // Return first result, cancel the other
        guard let result = try await group.next() else {
            throw URLError(.timedOut)
        }
        group.cancelAll()
        return result
    }
}
