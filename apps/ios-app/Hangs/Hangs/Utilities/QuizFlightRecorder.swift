//
//  QuizFlightRecorder.swift
//  Hangs
//
//  #186 step 1 — the quiz's black box. OSLog cannot be pulled off a field
//  device after the fact, and Sentry breadcrumbs only describe OUTPUTS
//  (transitions). What explains a broken screen is the INPUT trail — which tap,
//  command, timer, speech event or network answer arrived, for which question
//  attempt, in which state. This ring keeps the last few hundred of them in
//  memory; `HangsApp` attaches the dump to every Sentry event and the in-app
//  feedback report carries it too.
//
//  Metadata only — never a transcript or typed answer (Logging.swift rule).
//  Thread-safe and nonisolated: Sentry's `beforeSend` reads it off the main actor.
//

import Foundation
import os

nonisolated final class QuizFlightRecorder: Sendable {
    nonisolated enum Kind: String, Sendable {
        case tap, speech, command, timer, route, scene, network, prompt
        case state, attempt, drop, reject, invariant
    }

    nonisolated struct Entry: Sendable {
        let at: Date
        let kind: Kind
        let name: String
        let attempt: String
        let state: String
        let detail: String?
    }

    static let shared = QuizFlightRecorder()

    let capacity: Int
    private let storage = OSAllocatedUnfairLock<[Entry]>(initialState: [])

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    func record(_ kind: Kind, _ name: String, attempt: String, state: String, detail: String? = nil) {
        let entry = Entry(at: Date(), kind: kind, name: name, attempt: attempt, state: state, detail: detail)
        let capacity = capacity
        storage.withLock { entries in
            entries.append(entry)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
    }

    /// Oldest first.
    var entries: [Entry] {
        storage.withLock { $0 }
    }

    /// The last `count` events on one line — small enough to ride along as a
    /// Sentry log attribute on a stale drop or a rejected transition.
    func tail(_ count: Int) -> String {
        entries.suffix(count)
            .map { "\($0.kind.rawValue):\($0.name)@\($0.attempt)/\($0.state)" }
            .joined(separator: " | ")
    }

    /// Multi-line dump, oldest first, for Sentry events and feedback reports.
    func dump(last count: Int? = nil) -> String {
        let all = entries
        let slice = count.map { Array(all.suffix($0)) } ?? all
        // Built per call: a shared formatter would be a non-Sendable global.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        let lines = slice.map { entry in
            var line = "\(formatter.string(from: entry.at)) \(entry.kind.rawValue) \(entry.name)"
                + " attempt=\(entry.attempt) state=\(entry.state)"
            if let detail = entry.detail { line += " \(detail)" }
            return line
        }
        return "Quiz flight recorder — \(slice.count) of \(all.count) events\n" + lines.joined(separator: "\n")
    }

    /// Test seam: start a scenario from an empty ring.
    func removeAll() {
        storage.withLock { $0.removeAll() }
    }
}
