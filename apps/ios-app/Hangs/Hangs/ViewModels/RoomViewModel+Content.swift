//
//  RoomViewModel+Content.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 5A): "What we play" in the host's lobby.
//  A room's session is fixed once made, so other content means a new session.
//  #240.9: the room moves onto it with everyone in it, so a link the host
//  already sent keeps working and guests who joined stay in the game.
//

import Foundation
import os

extension RoomViewModel {
    /// The host can still pick what the room plays.
    var canChangeContent: Bool {
        isHost && packsEnabled() && state?.status == .lobby
    }

    /// Moves the lobby to a session with `newContent`; on failure the room stays.
    func play(_ newContent: RoomContent) async {
        guard newContent != content, canChangeContent, let old = created, let name = hostName else { return }
        let previous = content
        content = newContent
        isWorking = true
        defer { isWorking = false }
        do {
            let room = try await createRoom(hostName: name, moving: old.roomId)
            guard !hasLeft else {
                // Closed while it was on its way: nobody waits in a lobby without a host.
                try? await network.endSession(sessionId: room.sessionId)
                return
            }
            moveToRoom(room)
            // The room left the old session; nothing plays it any more.
            try? await network.endSession(sessionId: old.sessionId)
            await refresh()
            startPolling()
        } catch {
            guard !hasLeft else { return }
            Logger.network.error("Room content change failed: \(error, privacy: .public)")
            content = previous
            errorMessage = Self.genericMessage
        }
    }
}
