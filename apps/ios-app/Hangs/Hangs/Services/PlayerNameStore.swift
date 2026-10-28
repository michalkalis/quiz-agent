//
//  PlayerNameStore.swift
//  Hangs
//
//  #212: the name a player shows in a game together.
//

import Foundation

/// A name the player typed is kept for the next game. Until then a guest
/// plays under an automatic one (founder 2026-10-28); a host without an
/// account name is asked once.
struct PlayerNameStore {
    static let maxLength = 24

    private let defaults: UserDefaults
    private let key = "multiplayer.playerName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var chosenName: String? {
        defaults.string(forKey: key).flatMap(Self.cleaned)
    }

    func save(_ name: String) {
        guard let name = Self.cleaned(name) else { return }
        defaults.set(name, forKey: key)
    }

    /// The trimmed name within the server's 1–24 characters, nil when empty.
    static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxLength))
    }

    /// An automatic guest name in the UI language, e.g. "Rýchly gepard".
    static func automaticName(languageCode: String?, pick: (Int) -> Int = { Int.random(in: 0 ..< $0) }) -> String {
        let names = switch languageCode {
        case "sk": skNames
        case "cs": csNames
        default: enNames
        }
        return names[pick(names.count)]
    }

    private static let skNames = [
        "Rýchly gepard", "Múdra sova", "Veselý delfín", "Tichá líška",
        "Odvážny tiger", "Bystrá veverička", "Pokojný medveď", "Hravá vydra",
    ]
    private static let csNames = [
        "Rychlý gepard", "Moudrá sova", "Veselý delfín", "Tichá liška",
        "Odvážný tygr", "Bystrá veverka", "Klidný medvěd", "Hravá vydra",
    ]
    private static let enNames = [
        "Swift Cheetah", "Wise Owl", "Happy Dolphin", "Quiet Fox",
        "Brave Tiger", "Clever Squirrel", "Calm Bear", "Playful Otter",
    ]
}
