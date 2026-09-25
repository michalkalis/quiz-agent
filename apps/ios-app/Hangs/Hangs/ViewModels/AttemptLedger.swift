//
//  AttemptLedger.swift
//  Hangs
//
//  #186 step 1 — the ownership ticket for every async result in the quiz flow.
//
//  The state guards used to compare the phase LABEL (`== .processing`), and
//  `QuizState`'s Equatable ignores associated values, so a late result from
//  question N passed every guard during question N+1 (#185 finding 1: a late
//  400 opened an empty confirmation sheet on the next question). Cancellation
//  alone does not close that hole — a continuation already scheduled on the
//  main actor still writes. So every async path now captures the `AttemptID`
//  it was started for and asks this ledger before it writes any state; a
//  result that lost ownership is dropped and reported to Sentry, never applied.
//

import Foundation
import os

/// One answer attempt: the question it answers plus a monotonic counter.
/// A new attempt starts on question entry and on every new recording, submit,
/// skip, re-record, cancel or interruption, so a result captured for an older
/// attempt can never write into the one that replaced it.
nonisolated struct AttemptID: Hashable, Sendable, CustomStringConvertible {
    let questionId: String?
    let sequence: Int

    static let none = AttemptID(questionId: nil, sequence: 0)

    func isSameQuestion(as other: AttemptID) -> Bool {
        questionId == other.questionId
    }

    var description: String { "\(questionId ?? "-")#\(sequence)" }
}

/// The façade's single owner of the current `AttemptID`, handed to the child
/// coordinators exactly like `TaskBag` — a decision-4 handle, never a view
/// model reference. Also the one place stale drops, rejected transitions and
/// invariant violations are reported from, so all three reach Sentry (OSLog
/// alone is unreadable after the fact) and the flight recorder alike.
@MainActor
final class AttemptLedger {
    private(set) var current: AttemptID = .none
    private var sequence = 0
    let recorder: QuizFlightRecorder

    /// The façade's state label, for the recorder and the Sentry attributes.
    /// Assigned by the façade once it exists (the ledger is built first).
    var stateLabel: @MainActor () -> String = { "-" }

    /// Every invariant violation seen by this ledger — unit tests assert it
    /// stays empty across a flow (they run with the DEBUG assertion disarmed).
    private(set) var invariantViolations: [String] = []

    /// The paths of the most recent stale drops (capped) — what a unit test
    /// asserts when it proves a late result was dropped rather than applied.
    private(set) var droppedPaths: [String] = []

    init(recorder: QuizFlightRecorder = .shared) {
        self.recorder = recorder
    }

    // MARK: - Attempts

    /// Start a new attempt for `questionId` (question entry).
    @discardableResult
    func begin(questionId: String?, reason: String) -> AttemptID {
        sequence &+= 1
        current = AttemptID(questionId: questionId, sequence: sequence)
        record(.attempt, reason)
        return current
    }

    /// Start a new attempt on the SAME question (a recording, a submit, a skip,
    /// a cancel, an interruption): whatever the previous attempt still has in
    /// flight loses ownership here.
    @discardableResult
    func begin(_ reason: String) -> AttemptID {
        begin(questionId: current.questionId, reason: reason)
    }

    func isCurrent(_ attempt: AttemptID) -> Bool {
        attempt == current
    }

    /// The attempt whose answer has been sent (a confirm, the auto-confirm, a
    /// typed answer). Founder decision 2026-09-25: from then on the answer is
    /// final — "stop" / "again" for that attempt are dropped, never reopen it.
    private(set) var answerSent: AttemptID?

    func markAnswerSent() {
        answerSent = current
    }

    /// `true` = the current attempt's answer is already sent: the caller's
    /// action is dropped and reported like any other late input.
    func refuseAfterAnswerSent(_ path: String) -> Bool {
        guard let answerSent, answerSent == current else { return false }
        reportStale(path, owner: answerSent)
        return true
    }

    /// Owner check for an ATTEMPT-scoped result (upload, transcript, read-back,
    /// prompt, auto-confirm, recording window). `false` = dropped and reported.
    func owns(_ attempt: AttemptID, _ path: String) -> Bool {
        guard attempt != current else { return true }
        reportStale(path, owner: attempt)
        return false
    }

    /// Owner check for a QUESTION-scoped result (the question read-out tail,
    /// the think/answer countdowns, auto-advance, the skip undo window): any
    /// attempt on the same question still owns it; another question never does.
    func ownsQuestion(_ attempt: AttemptID, _ path: String) -> Bool {
        guard !attempt.isSameQuestion(as: current) else { return true }
        reportStale(path, owner: attempt)
        return false
    }

    // MARK: - Black box + reports

    func record(_ kind: QuizFlightRecorder.Kind, _ name: String, _ detail: String? = nil) {
        recorder.record(kind, name, attempt: current.description, state: stateLabel(), detail: detail)
    }

    func reportRejectedTransition(from: String, to: String, caller: String) {
        record(.reject, "\(from)→\(to)", caller)
        SentryLog.warn("quiz transition rejected", category: .quiz, attributes: [
            "from": from, "to": to, "caller": caller,
            "attempt": current.description, "recent": recorder.tail(8),
        ])
    }

    /// A state the quiz must never be in. Reported in every build; a DEBUG app
    /// run also stops on it. Unit tests keep running (they poke state directly
    /// and assert `invariantViolations` instead).
    func reportInvariantViolation(_ invariant: String, _ detail: String) {
        invariantViolations.append(invariant)
        record(.invariant, invariant, detail)
        SentryLog.error("quiz invariant violated", category: .quiz, attributes: [
            "invariant": invariant, "detail": detail,
            "attempt": current.description, "state": stateLabel(), "recent": recorder.tail(12),
        ])
        #if DEBUG
            if !Self.isRunningUnitTests {
                assertionFailure("Quiz invariant violated: \(invariant) — \(detail)")
            }
        #endif
    }

    private func reportStale(_ path: String, owner: AttemptID) {
        droppedPaths.append(path)
        if droppedPaths.count > 50 { droppedPaths.removeFirst(droppedPaths.count - 50) }
        record(.drop, path, "owner=\(owner)")
        SentryLog.warn("stale async result dropped", category: .quiz, attributes: [
            "path": path, "owner": owner.description, "current": current.description,
            "state": stateLabel(), "recent": recorder.tail(8),
        ])
    }

    #if DEBUG
        private static let isRunningUnitTests =
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #endif
}
