//
//  RoomInviteInbox.swift
//  Hangs
//
//  #212: a join link (QR code or message) waits here until Home can open it.
//

import Combine
import Foundation

@MainActor
final class RoomInviteInbox: ObservableObject {
    @Published private(set) var invite: RoomInvite?

    /// True when `url` is a game invite (it is then kept for Home).
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let invite = RoomInvite.invite(from: url) else { return false }
        self.invite = invite
        return true
    }

    func take() -> RoomInvite? {
        defer { invite = nil }
        return invite
    }
}
