//
//  MultiplayerSettingsStore.swift
//  Hangs
//
//  #213.8: the host's rules for a game together, kept for the next game.
//

import Foundation

/// JSON in UserDefaults like the solo settings, under its own key. A missing
/// or unreadable value falls back to the defaults for most players.
struct MultiplayerSettingsStore {
    private let defaults: UserDefaults
    private let key = "multiplayer_settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MultiplayerSettings {
        guard let data = defaults.data(forKey: key),
              var settings = try? JSONDecoder().decode(MultiplayerSettings.self, from: data)
        else { return MultiplayerSettings() }
        let range = MultiplayerSettings.thinkingRange
        settings.thinkingSeconds = min(max(settings.thinkingSeconds, range.lowerBound), range.upperBound)
        return settings
    }

    func save(_ settings: MultiplayerSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
