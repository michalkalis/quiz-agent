//
//  RoomViewModel+Settings.swift
//  Hangs
//
//  #213.8: the host changes the rules of a game together, in the lobby or
//  mid-game. A change is kept on the device and sent to the room; if the
//  room refuses it, both go back to what they were.
//

import Foundation

extension RoomViewModel {
    /// The reveal is fixed once the game starts (the server answers 409).
    var canChangeRevealMode: Bool { isHost && state?.status == .lobby }

    func setRevealMode(_ mode: RoomState.RevealMode) async {
        guard canChangeRevealMode, mode != settings.revealMode else { return }
        var new = settings
        new.revealMode = mode
        await change(to: new, setting: .revealMode, value: mode.rawValue) { roomId in
            try await self.rooms.updateSettings(roomId: roomId, revealMode: mode, thinkingSeconds: nil, readsAloud: nil)
        }
    }

    /// Mid-game the server applies the new time from the next question.
    func setThinkingSeconds(_ seconds: Int) async {
        guard MultiplayerSettings.thinkingRange.contains(seconds), seconds != settings.thinkingSeconds else { return }
        var new = settings
        new.thinkingSeconds = seconds
        await change(to: new, setting: .thinkingSeconds, value: String(seconds)) { roomId in
            try await self.rooms.updateSettings(roomId: roomId, revealMode: nil, thinkingSeconds: seconds, readsAloud: nil)
        }
    }

    func setReadsAloud(_ on: Bool) async {
        guard on != settings.readsAloud else { return }
        var new = settings
        new.readsAloud = on
        // The game may have started silent, without the audio session.
        if on, state?.status == .playing { prepareReadAloudAudio() }
        await change(to: new, setting: .readsAloud, value: String(on)) { roomId in
            try await self.rooms.updateSettings(roomId: roomId, revealMode: nil, thinkingSeconds: nil, readsAloud: on)
        }
    }

    private func change(
        to new: MultiplayerSettings,
        setting: RoomSettingKind,
        value: String,
        send: (String) async throws -> RoomState
    ) async {
        guard isHost, !isSavingSettings else { return }
        let old = settings
        let surface: RoomSettingsSurface = state?.status == .playing ? .inGame : .lobby
        settings = new
        settingsStore.save(new)
        if let roomId = created?.roomId {
            isSavingSettings = true
            defer { isSavingSettings = false }
            do {
                try apply(await send(roomId))
            } catch {
                settings = old
                settingsStore.save(old)
                errorMessage = Self.genericMessage
                return
            }
        }
        analytics.track(.roomSettingsChanged(setting: setting, value: value, surface: surface))
    }
}
