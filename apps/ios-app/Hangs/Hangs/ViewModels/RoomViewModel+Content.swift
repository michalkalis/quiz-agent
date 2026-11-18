//
//  RoomViewModel+Content.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 5A): "What we play" in the host's lobby.
//  A room's session is fixed once made, so other content means a new session
//  and room; the old one is ended. Only while nobody has joined yet, so no
//  guest is left in a closed room.
//

import Foundation
import os

extension RoomViewModel {
    /// The host can still pick what the room plays.
    var canChangeContent: Bool {
        isHost && packsEnabled() && state?.status == .lobby && !players.contains { !$0.isHost }
    }

    /// Moves the lobby to a room with `newContent`; on failure the room stays.
    func play(_ newContent: RoomContent) async {
        guard newContent != content, canChangeContent, let old = created, let name = hostName else { return }
        let previous = content
        content = newContent
        isWorking = true
        defer { isWorking = false }
        do {
            let room = try await createRoom(hostName: name)
            moveToRoom(room)
            try? await network.endSession(sessionId: old.sessionId)
            await refresh()
            startPolling()
        } catch {
            Logger.network.error("Room content change failed: \(error, privacy: .public)")
            content = previous
            errorMessage = Self.genericMessage
        }
    }
}
