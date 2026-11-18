//
//  SharedQuizUnavailable.swift
//  Hangs
//
//  #232: why a shared quiz cannot be created or started.
//

import Foundation

/// Why a shared quiz cannot be created or started (the server's 404/409 codes).
nonisolated enum SharedQuizUnavailable: Equatable, Sendable {
    /// Unknown token, or the feature is switched off.
    case notFound
    /// This person already played it (a shared pack plays once; today's
    /// challenge was played, also in another language).
    case alreadyPlayed
    /// None of its questions can be played on this build any more.
    case nothingPlayable
    /// The sender's quiz or pack is not finished, or holds nothing to share.
    case notShareable

    init(statusCode: Int, code: String?) {
        switch code {
        case "already_played", "daily_played_other_language": self = .alreadyPlayed
        case "nothing_playable": self = .nothingPlayable
        case "not_finished", "pack_not_finished", "nothing_to_share": self = .notShareable
        default: self = statusCode == 409 ? .notShareable : .notFound
        }
    }

    var message: String {
        switch self {
        case .notFound:
            String(localized: "This quiz link no longer works.", bundle: .interface, locale: .interface, comment: "#232: a shared quiz link is unknown or switched off")
        case .alreadyPlayed:
            String(localized: "You've already played this quiz.", bundle: .interface, locale: .interface, comment: "#232: a shared quiz this player already played")
        case .nothingPlayable:
            String(localized: "This quiz can't be played any more.", bundle: .interface, locale: .interface, comment: "#232: none of a shared quiz's questions can be played")
        case .notShareable:
            String(localized: "This quiz can't be sent yet.", bundle: .interface, locale: .interface, comment: "#232: the server refused to share an unfinished quiz or pack")
        }
    }
}
