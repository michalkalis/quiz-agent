//
//  RoomContent.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 5A): what a game together plays: a
//  category choice, or one of the host's finished custom packs. #249.1: the
//  category choice is the room's own (`MultiplayerSettings.categories`), no
//  longer the solo selection on Home.
//

import Foundation

nonisolated enum RoomContent: Equatable, Sendable {
    case categories
    case pack(id: String, title: String)

    var packId: String? {
        if case let .pack(id, _) = self { return id }
        return nil
    }
}
