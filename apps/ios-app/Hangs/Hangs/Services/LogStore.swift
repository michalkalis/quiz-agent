//
//  LogStore.swift
//  Hangs
//
//  Reads back OS Logger entries via OSLogStore for in-app debug inspection.
//  Only compiled in DEBUG — production builds do not need the reader layer and
//  OSLogStore's `.currentProcessIdentifier` scope is primarily a dev-tool affordance.
//

#if DEBUG
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
}
#endif
