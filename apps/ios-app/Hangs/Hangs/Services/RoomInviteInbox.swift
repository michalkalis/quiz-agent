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
    @Published private(set) var token: String?

    /// True when `url` is a game invite (it is then kept for Home).
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let token = RoomInvite.token(from: url) else { return false }
        self.token = token
        return true
    }

    func take() -> String? {
        defer { token = nil }
        return token
    }
}
