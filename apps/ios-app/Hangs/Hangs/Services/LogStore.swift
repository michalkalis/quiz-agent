//
//  LogStore.swift
//  Hangs
//
//  Reads back OS Logger entries via OSLogStore for in-app log inspection.
//  Compiled in ALL configurations (#109): the in-app feedback path attaches the
//  recent-log tail from release builds too, so the reader can no longer be
//  DEBUG-only. The interactive viewer (`DebugLogView`) stays DEBUG-gated.
//  OSLogStore's `.currentProcessIdentifier` scope reads only our own process,
//  which needs no entitlement.
//

import Foundation
import OSLog

actor LogStore {
    static let shared = LogStore()

    private let subsystem: String

    init(subsystem: String = "com.missinghue.hangs") {
        self.subsystem = subsystem
    }

    /// Fetch log entries written in the last `sinceMinutes` for this process.
    /// `OSLogStore.local()` requires `com.apple.developer.logging.private-level` entitlement
    /// to read other processes' logs; for our own subsystem `currentProcessIdentifier` is sufficient.
    func fetch(sinceMinutes: Int = 60, limit: Int = 500) async -> [LogEntry] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-Double(sinceMinutes) * 60))

            // Predicate at the store level is faster than in-Swift filtering for large buffers.
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let osEntries = try store.getEntries(at: start, matching: predicate)

            var results: [LogEntry] = []
            results.reserveCapacity(min(limit, 500))

            for case let entry as OSLogEntryLog in osEntries {
                let logEntry = LogEntry(
                    date: entry.date,
                    category: entry.category,
                    level: LogEntry.Level(osLogLevel: entry.level),
                    message: entry.composedMessage
                )
                results.append(logEntry)
            }

            // Newest-first, capped. `osEntries` is oldest-first so reversing is fine.
            if results.count > limit {
                results.removeFirst(results.count - limit)
            }
            return results.reversed()
        } catch {
            // Surface the read failure as a synthetic entry so the UI explains why the list is empty.
            return [LogEntry(
                date: Date(),
                category: "logstore",
                level: .error,
                message: "OSLogStore read failed: \(error.localizedDescription)"
            )]
        }
    }

    /// Plain-text export of recent logs for attachment to an in-app feedback
    /// report (#109). Chronological (oldest → newest); tail-capped to `maxBytes`
    /// so an oversized buffer never blows the backend's 1 MB logs cap — the tail
    /// is kept because the most recent lines are the ones that explain the
    /// screen the user was on. Reuses `LogEntry.formatted()` (the same one-line
    /// rendering `DebugLogView`'s share-sheet export uses).
    func exportText(sinceMinutes: Int = 15, maxBytes: Int = 200_000) async -> String {
        // fetch(...) returns newest-first; reverse to chronological for the export.
        let entries = Array(await fetch(sinceMinutes: sinceMinutes, limit: 2000).reversed())
        let header = "Hangs log export — \(Date())\nSubsystem: \(subsystem)\nEntries: \(entries.count)\n\n"
        let full = header + entries.map { $0.formatted() }.joined(separator: "\n")

        let data = Data(full.utf8)
        guard data.count > maxBytes else { return full }

        // Keep the most recent `maxBytes`. Decode leniently — a byte-slice may
        // split a multi-byte character at the boundary.
        let tail = data.suffix(maxBytes)
        let tailText = String(decoding: tail, as: UTF8.self)
        return "…[truncated to last \(maxBytes) bytes]…\n" + tailText
    }
}
