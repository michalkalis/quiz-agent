//
//  DailyChallengeDay.swift
//  Hangs
//
//  #205: the day a daily challenge belongs to — the device's local calendar
//  date, sent to the server as `YYYY-MM-DD` and shown as "15. 10." (sk, cs),
//  "15 жовтня" (uk) or "Oct 15" (en).
//

import Foundation

nonisolated struct DailyChallengeDay: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    private static let englishMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// #231: Ukrainian names the month in the genitive after the day ("18 листопада").
    private static let ukrainianMonths = [
        "січня", "лютого", "березня", "квітня", "травня", "червня",
        "липня", "серпня", "вересня", "жовтня", "листопада", "грудня",
    ]

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local date of `date` in the time zone of `calendar`, always
    /// counted in the Gregorian calendar: the server reads `YYYY-MM-DD` as
    /// Gregorian, and a phone set to the Japanese or Buddhist calendar would
    /// otherwise send "8-10-15" or 2569 (#240 audit finding 18).
    init(_ date: Date, calendar: Calendar = .current) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
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

    /// "15. 10." in Slovak and Czech, "15 жовтня" in Ukrainian, "Oct 15" otherwise.
    func label(languageCode: String) -> String {
        switch languageCode {
        case "sk", "cs": "\(day). \(month)."
        case "uk": "\(day) \(Self.ukrainianMonths[month - 1])"
        default: "\(Self.englishMonths[month - 1]) \(day)"
        }
    }
}
