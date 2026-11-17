//
//  PendingRoomLeave.swift
//  Hangs
//
//  #235 F5: closing a game together tells the server in the background (a
//  guest drops out, a host ends the game). When that never arrives the host
//  keeps seeing the guest, or the host's room stays open until the server
//  drops it. The one unsent leave is kept on the phone and sent again on the
//  next app start and the next time the Together tab opens. Nothing is shown
//  to the player.
//

import Foundation

enum PendingRoomLeave: Codable, Equatable, Sendable {
    case guest(roomId: String, participantId: String)
    case host(sessionId: String)
}
