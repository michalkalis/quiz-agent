//
//  TaskBag.swift
//  Hangs
//
//  Centralised lifecycle for keyed concurrent Tasks. Replaces a swarm of
//  `var Task?` properties in `QuizViewModel` with one `add / cancel /
//  cancelAll` API. Adding a new timer becomes a one-edit change: append a
//  case to `TaskKey` and call `taskBag.add(_:key:)` at the start site.
//

import Foundation

/// Stable identifiers for every long-lived `Task` `QuizViewModel` owns.
/// Adding a new background job means adding a case here — nothing else is
/// keyed by string, so there is no chance of typos or drift.
enum TaskKey: Hashable, Sendable {
    case autoAdvance
    case voiceSubmission
    case answerTimer
    case autoStopRecording
    case silenceDetection
    case autoConfirm
    case thinkingTime
    case sttEvent
    case sttChunk
    case bargeIn
}

/// Owns a set of `Task<Void, Never>` handles keyed by `TaskKey`. Adding a
/// new task under a key already in the bag cancels the previous handle —
/// callers no longer have to write the cancel-then-replace dance.
///
/// Marked `@MainActor` to mirror `QuizViewModel`'s isolation: every
/// mutation is serialised on the main thread, so `add`/`cancel`/`cancelAll`
/// are linearisable without extra locking.
@MainActor
final class TaskBag {
    private var tasks: [TaskKey: Task<Void, Never>] = [:]

    init() {}

    /// Store `task` under `key`, cancelling any previous task at the same
    /// key. Cancellation is fire-and-forget — the previous task observes
    /// the cancellation on its next suspension point.
    func add(_ task: Task<Void, Never>, key: TaskKey) {
        tasks[key]?.cancel()
        tasks[key] = task
    }

    /// Cancel and forget the task at `key`. No-op if no task is registered.
    func cancel(_ key: TaskKey) {
        tasks[key]?.cancel()
        tasks.removeValue(forKey: key)
    }

    /// Cancel and forget every task in the bag. Used by `resetState()` and
    /// other "stop everything" paths to avoid duplicating the per-key list.
    func cancelAll() {
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
    }

    /// Test/diagnostics hook: whether a task is currently registered under
    /// `key`. Does not inspect cancellation state — a task that has finished
    /// naturally may still appear here until something replaces or cancels it.
    func contains(_ key: TaskKey) -> Bool {
        tasks[key] != nil
    }

    /// Number of registered tasks. Test/diagnostics only.
    var count: Int {
        tasks.count
    }
}
