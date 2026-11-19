//
//  MultiplayerSettingsStore.swift
//  Hangs
//
//  #213.8: the host's rules for a game together, kept for the next game.
//  #240.9: only the rules the host picked are kept, so a new default reaches
//  every host who never chose that rule.
//

import Foundation

/// JSON in UserDefaults like the solo settings, under its own key. A missing
/// or unreadable value falls back to the defaults for most players.
struct MultiplayerSettingsStore {
    /// The rules the host picked; nil = the current default.
    nonisolated struct Choices: Codable, Equatable, Sendable {
        var revealMode: RoomState.RevealMode?
        var thinkingSeconds: Int?
        var readsAloud: Bool?
        /// 2 = only picked rules are stored. Builds before #240.9 stored every
        /// rule without it (see `fromBefore240`).
        var format: Int?

        static let currentFormat = 2

        init(revealMode: RoomState.RevealMode? = nil, thinkingSeconds: Int? = nil, readsAloud: Bool? = nil) {
            self.revealMode = revealMode
            self.thinkingSeconds = thinkingSeconds
            self.readsAloud = readsAloud
            format = Self.currentFormat
        }

        init(_ settings: MultiplayerSettings) {
            self.init(revealMode: settings.revealMode, thinkingSeconds: settings.thinkingSeconds, readsAloud: settings.readsAloud)
        }

        var settings: MultiplayerSettings {
            var settings = MultiplayerSettings()
            if let revealMode { settings.revealMode = revealMode }
            if let thinkingSeconds {
                let range = MultiplayerSettings.thinkingRange
                settings.thinkingSeconds = min(max(thinkingSeconds, range.lowerBound), range.upperBound)
            }
            if let readsAloud { settings.readsAloud = readsAloud }
            return settings
        }

        /// Marks one rule as picked, with its value from `settings`.
        mutating func pick(_ kind: RoomSettingKind, from settings: MultiplayerSettings) {
            switch kind {
            case .revealMode: revealMode = settings.revealMode
            case .thinkingSeconds: thinkingSeconds = settings.thinkingSeconds
            case .readsAloud: readsAloud = settings.readsAloud
            }
        }

        /// Older builds saved every rule whenever one changed, so a stored
        /// default cannot be told from a pick. A value other than that old
        /// default was picked and stays; the old defaults (results at the end,
        /// 30 s, read aloud) give way to the new ones (founder 2026-11-18).
        var fromBefore240: Choices {
            Choices(
                revealMode: revealMode == .round ? nil : revealMode,
                thinkingSeconds: thinkingSeconds == 30 ? nil : thinkingSeconds,
                readsAloud: readsAloud == true ? nil : readsAloud
            )
        }

        enum CodingKeys: String, CodingKey {
            case revealMode = "reveal_mode"
            case thinkingSeconds = "thinking_seconds"
            case readsAloud = "reads_aloud"
            case format
        }
    }

    private let defaults: UserDefaults
    private let key = "multiplayer_settings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MultiplayerSettings {
        loadChoices().settings
    }

    func loadChoices() -> Choices {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(Choices.self, from: data)
        else { return Choices() }
        return stored.format == Choices.currentFormat ? stored : stored.fromBefore240
    }

    /// Every rule as picked (a host who set them all).
    func save(_ settings: MultiplayerSettings) {
        save(Choices(settings))
    }

    func save(_ choices: Choices) {
        var choices = choices
        choices.format = Choices.currentFormat
        guard let data = try? JSONEncoder().encode(choices) else { return }
        defaults.set(data, forKey: key)
    }
}
