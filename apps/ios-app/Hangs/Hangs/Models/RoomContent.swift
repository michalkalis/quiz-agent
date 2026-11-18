//
//  RoomContent.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 5A): what a game together plays: the
//  categories set on Home, or one of the host's finished custom packs.
//

import Foundation

nonisolated enum RoomContent: Equatable, Sendable {
    case home
    case pack(id: String, title: String)

    var packId: String? {
        if case let .pack(id, _) = self { return id }
        return nil
    }
}
