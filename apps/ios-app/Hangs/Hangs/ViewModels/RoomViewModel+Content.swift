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

    /// The room's categories, minus an extra the server no longer lists, so a
    /// rotated-out or switched-off extra never reaches the new session.
    var offeredCategories: [String] {
        let listed = Set(extraCategories().map(\.key))
        return settings.categories.filter { !ExtraCategory.isExtra($0) || listed.contains($0) }
    }

    /// "All Categories", the one category's name, or a count: the lobby row's summary.
    var categorySummary: String {
        var shown = solo
        shown.categories = offeredCategories
        return shown.categoryDisplayName(extras: extraCategories())
    }

    /// Moves the lobby to a session with `newContent` (and, for categories,
    /// the host's `categories`); on failure the room and the choice stay.
    /// The room's categories are kept apart from solo's (#212, #249.1).
    func play(_ newContent: RoomContent, categories newCategories: [String]? = nil) async {
        let target = newContent == .categories ? (newCategories ?? settings.categories) : settings.categories
        let changesCategories = newContent == .categories && target != settings.categories
        guard newContent != content || changesCategories, canChangeContent, let old = created, let name = hostName else { return }
        let previous = content
        let previousSettings = settings
        let previousChoices = settingsStore.loadChoices()
        content = newContent
        if changesCategories {
            settings.categories = target
            var choices = previousChoices
            choices.pick(.categories, from: settings)
            settingsStore.save(choices)
        }
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
            if changesCategories {
                analytics.track(.roomSettingsChanged(setting: .categories, value: target.isEmpty ? "all" : target.joined(separator: ","), surface: .lobby))
            }
            await refresh()
            startPolling()
        } catch {
            guard !hasLeft else { return }
            Logger.network.error("Room content change failed: \(error, privacy: .public)")
            content = previous
            settings = previousSettings
            settingsStore.save(previousChoices)
            errorMessage = Self.genericMessage
        }
    }
}
