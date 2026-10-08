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
//  #133 1a — why retrying a submit is now SAFE rather than merely narrow: every
//  submit carries the `question_id` it answers, and the server is question-scoped
//  idempotent (`SubmitInputRequest.question_id` / the voice route's `question_id`
//  query param). A re-sent submission whose id matches the question the session
//  last graded is replayed — or re-graded against that same question when the text
//  changed — never double-charging quota and never advancing twice. So the old
//  hazard (server processed, response lost on a tunnel, retry answers the NEXT
//  question) is closed at the protocol level. The retry classes below stay exactly
//  as narrow as before: this is defence in depth, not a licence to widen them.
//  A 409 `question_mismatch` is deliberately NOT retryable — it proves the request
//  reached application code, and re-sending the same stale id fails identically.
//
//  #193 — beta hardening, task 193.12: the bound is a TIME WINDOW, not an attempt
//  count. Prod `quiz-agent-api` is a single machine, so every deploy restarts it
//  for ~18 s; three attempts 1 s + 2 s apart gave up after ~3 s and a deploy
//  mid-drive failed the player's answer. Retries now keep coming (1 s, 2 s, then
//  every 3 s) until the next one would start more than `retryWindow` after the
//  first, which covers a ~18–24 s restart while still landing inside the 30 s
//  user-facing submit bound. A window also caps the slow case the count never
//  did: an attempt that itself burns the 30 s URLSession timeout is not retried
//  (quiz start used to stack 3 × 30 s). Callers must stay idempotent: question-
//  scoped submits/skips, quiz start (an orphaned session expires). Purchases and
//  pack orders never go through here.
//

import Clocks
import Foundation
import os

enum TransientRetry {
    /// No retry starts later than this after the first attempt (#193 task 193.12).
    nonisolated static let retryWindow: Duration = .seconds(24)

    /// Backoff after the `attempt`-th failure: 1 s, 2 s, then a steady 3 s, so a
    /// machine that comes back is picked up within ~3 s.
    nonisolated static func delay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(attempt, 3))
    }

    /// Classifies an error as a transient cold-start / edge-proxy failure worth a
    /// bounded retry. Only connection-level `URLError`s (the machine is asleep or
    /// restarting so the socket never connects, or the phone briefly lost signal)
    /// and Fly-proxy / backend 502-503-504 (returned while the machine wakes or
    /// restarts, or by the backend's own retryable-error envelope) qualify.
    /// Everything else — 401, 429/quota, other 4xx, decoding errors — is permanent
    /// and must surface immediately, never retry.
    nonisolated static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        if let networkError = error as? NetworkError,
           case let .serverError(statusCode, _) = networkError
        {
            return statusCode == 502 || statusCode == 503 || statusCode == 504
        }
        return false
    }

    /// Runs `operation`, retrying it while `isTransient` holds and the next attempt
    /// would still start within `retryWindow` of the first. `label` names the
    /// operation in the log/Sentry breadcrumb; `clock` is the seam that takes the
    /// wait off real time in tests (#180 track A).
    @MainActor
    static func run<T>(
        label: String,
        clock: AnyClock<Duration> = .continuous,
        _ operation: () async throws -> T
    ) async throws -> T {
        let start = clock.now
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                let backoff = delay(afterAttempt: attempt)
                guard isTransient(error),
                      start.duration(to: clock.now) + backoff <= retryWindow
                else { throw error }
                Logger.network.warning("⏳ Transient error on \(label, privacy: .public) (attempt \(attempt, privacy: .public)), retrying in \(backoff, privacy: .public): \(error, privacy: .public)")
                SentryLog.info(
                    "retrying transient error",
                    category: .network,
                    attributes: ["operation": label, "attempt": attempt, "error": String(describing: error)]
                )
                // `try` (not `try?`): a cancelled operation (Home "Cancel" tap, a
                // cancelled submission) must abort the backoff immediately rather than
                // swallow the cancellation and retry anyway.
                try await clock.sleep(for: backoff)
                attempt += 1
            }
        }
    }
}
