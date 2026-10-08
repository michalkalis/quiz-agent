//
//  ResetCountdown.swift
//  Hangs
//
//  The paywall's "free questions reset in …" value (#93). Moved out of
//  PaywallView's countdown pill in #194 A1.
//

import Foundation

enum ResetCountdown {
    /// The pill shows minutes at the finest, so it refreshes once a minute.
    static let refreshInterval: Duration = .seconds(60)

    /// Compact time left: "12d 4h" from a day out, "3h 5m" from an hour out,
    /// "5m" below that, and "now" once the reset is due.
    static func text(until resetDate: Date, now: Date) -> String {
        let remaining = resetDate.timeIntervalSince(now)
        guard remaining > 0 else {
            return String(localized: "now", comment: "Countdown pill value when free questions reset imminently")
        }
        let days = Int(remaining) / 86400
        let hours = (Int(remaining) % 86400) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if days > 0 {
            return String(localized: "\(days)d \(hours)h", comment: "Compact time remaining: days and hours (e.g. 12d 4h)")
        } else if hours > 0 {
            return String(localized: "\(hours)h \(minutes)m", comment: "Compact time remaining: hours and minutes (e.g. 3h 5m)")
        } else {
            return String(localized: "\(minutes)m", comment: "Compact time remaining: minutes only (e.g. 5m)")
        }
    }
}
