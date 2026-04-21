//
//  LogEntry.swift
//  Hangs
//
//  Value type for in-app log inspection. Populated from OSLogStore — mirrors `os.Logger`
//  entries written by the app without duplicating the logging layer.
//

import Foundation
import OSLog

struct LogEntry: Identifiable, Hashable, Sendable {
    enum Level: String, CaseIterable, Sendable {
        case debug, info, notice, warning, error, fault

        var sortOrder: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .notice: return 2
            case .warning: return 3
            case .error: return 4
            case .fault: return 5
            }
        }

        nonisolated init(osLogLevel: OSLogEntryLog.Level) {
            switch osLogLevel {
            case .debug: self = .debug
            case .info: self = .info
            case .notice: self = .notice
            case .error: self = .error
            case .fault: self = .fault
            case .undefined: self = .info
            @unknown default: self = .info
            }
        }
    }

    let id = UUID()
    let date: Date
    let category: String
    let level: Level
    let message: String

    /// One-line plain-text rendering suitable for share sheets.
    func formatted() -> String {
        let ts = Self.formatter.string(from: date)
        return "\(ts) [\(level.rawValue.uppercased())] [\(category)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
