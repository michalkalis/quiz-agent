//
//  TransientRetry.swift
//  Hangs
//
//  #131 Track A. The bounded cold-wake retry policy that quiz-start has carried
//  since #100, lifted out of QuizViewModel so the SUBMIT paths reuse it verbatim.
//
//  Why it had to move: staging runs on `auto_stop_machines`, so the FIRST request
//  after an idle period hits a waking machine and comes back as a connection-level
//  URLError or a Fly-proxy 502/503. Quiz start retried and recovered; voice submit,
//  skip and typed submit did not — one cold wake surfaced "Couldn't submit your
//  answer" (founder TF report, 2026-07-29 10:40). The backend now answers transient
//  input-route failures with a retryable 503 (commit 99d79a8d), which lands in the
//  same `serverError(503)` bucket below.
//
//  Bounded on purpose: 3 attempts, 1s then 2s. Only failures that PROVE the request
//  never reached application code qualify — a retried submit must never double-count
//  an answer.
//

import Foundation
import os

enum TransientRetry {
    /// 1 initial attempt + 2 retries.
    static let maxAttempts = 3

    /// Classifies an error as a transient cold-start / edge-proxy failure worth a
    /// bounded retry. Only connection-level `URLError`s (the machine is asleep so the
    /// socket never connects) and Fly-proxy / backend 502-503 (returned while the
    /// machine wakes, or by the backend's own retryable-error envelope) qualify.
    /// Everything else — 401, 429/quota, other 4xx, decoding errors — is permanent
    /// and must surface immediately, never retry.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .cannotFindHost, .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        if let networkError = error as? NetworkError,
           case let .serverError(statusCode, _) = networkError
        {
            return statusCode == 502 || statusCode == 503
        }
        return false
    }

    /// Runs `operation`, retrying it up to `maxAttempts` times while `isTransient`
    /// holds. `label` names the operation in the log/Sentry breadcrumb; `backoff` is
    /// the test seam that collapses the wait.
    @MainActor
    static func run<T>(
        label: String,
        backoff: (@Sendable (Int) -> Duration)? = nil,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, isTransient(error) else { throw error }
                let delay = backoff?(attempt) ?? .seconds(Double(attempt)) // 1s, then 2s
                Logger.network.warning("⏳ Transient error on \(label, privacy: .public) (attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)), retrying: \(error, privacy: .public)")
                SentryLog.info(
                    "retrying transient error",
                    category: .network,
                    attributes: ["operation": label, "attempt": attempt, "error": String(describing: error)]
                )
                // `try` (not `try?`): a cancelled operation (Home "Cancel" tap, a
                // cancelled submission) must abort the backoff immediately rather than
                // swallow the cancellation and retry anyway.
                try await Task.sleep(for: delay)
                attempt += 1
            }
        }
    }
}
