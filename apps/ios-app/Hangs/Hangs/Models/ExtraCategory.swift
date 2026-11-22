//
//  ExtraCategory.swift
//  Hangs
//
//  #242 — the free rotating extra categories (plan
//  docs/issues/issue-242-extra-categories-rotation.md, step 242.5): what the
//  server offers now, and the two calm messages for a category that is gone or
//  played through. Names come from the server in the quiz language.
//

import Foundation

/// One extra category (`GET /api/v1/categories/extra`, backend `ExtraCategory`).
nonisolated struct ExtraCategory: Codable, Equatable, Sendable, Identifiable {
    /// The `extra-*` key a session is created with.
    let key: String
    /// Already in the asked language.
    let name: String
    /// ISO date of the last day on offer; nil = no end announced.
    let until: String?

    var id: String { key }

    static let keyPrefix = "extra-"

    static func isExtra(_ id: String) -> Bool {
        id.hasPrefix(keyPrefix)
    }

    /// "30. nov." in the screen's language; the date is the server's UTC day,
    /// so it is read and written in UTC and never shifts with the phone's zone.
    func untilLabel(locale: Locale) -> String? {
        guard let until, let date = try? Date(until, strategy: Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day()) else { return nil }
        return date.formatted(Date.FormatStyle(timeZone: .gmt).locale(locale).day().month(.abbreviated))
    }
}

/// `GET /api/v1/categories/extra?language=`.
nonisolated struct ExtraCategoriesResponse: Codable, Equatable, Sendable {
    let categories: [ExtraCategory]
}

/// The two answers of a start that names an extra category the player cannot
/// play. Plain words, one way back (OK), never a reset-history offer.
nonisolated enum ExtraCategoryNotice {
    static var exhausted: String {
        String(localized: "You have played through this category. Try another.", bundle: .interface, locale: .interface, comment: "#242: Home alert, the free extra category has no question left this phone has not played")
    }

    static var invalid: String {
        String(localized: "This category is no longer on offer. Back to all categories.", bundle: .interface, locale: .interface, comment: "#242: Home alert, the free extra category rotated out; the selection went back to all categories")
    }
}
