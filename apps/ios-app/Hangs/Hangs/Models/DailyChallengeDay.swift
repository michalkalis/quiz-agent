//
//  DailyChallengeDay.swift
//  Hangs
//
//  #205: the day a daily challenge belongs to — the device's local calendar
//  date, sent to the server as `YYYY-MM-DD` and shown as "15. 10." (sk, cs)
//  or "Oct 15" (en).
//

import Foundation

nonisolated struct DailyChallengeDay: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    private static let englishMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar date of `date` (time zone and calendar of the device).
    init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Parses the server's `YYYY-MM-DD`; nil for anything else.
    init?(isoDate: String) {
        let parts = isoDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1 ... 12).contains(parts[1]), (1 ... 31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    var isoDate: String {
        "\(year)-\(Self.twoDigits(month))-\(Self.twoDigits(day))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// "15. 10." in Slovak and Czech, "Oct 15" otherwise.
    func label(languageCode: String) -> String {
        switch languageCode {
        case "sk", "cs": "\(day). \(month)."
        default: "\(Self.englishMonths[month - 1]) \(day)"
        }
    }
}
