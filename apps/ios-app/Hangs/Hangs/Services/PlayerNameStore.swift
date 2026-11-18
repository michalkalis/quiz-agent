//
//  PlayerNameStore.swift
//  Hangs
//
//  #212: the name a player shows in a game together.
//

import Foundation

/// A name the player typed (in a game together or in the Profile) is kept
/// and wins over the Apple account's first name. Without either a guest plays
/// under an automatic one (founder 2026-10-28); a host is asked once.
struct PlayerNameStore {
    static let maxLength = 24

    private let defaults: UserDefaults
    private let key = "multiplayer.playerName"
    /// Internal so a snapshot can pin the automatic name.
    static let automaticKey = "sharedQuiz.automaticName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var chosenName: String? {
        defaults.string(forKey: key).flatMap(Self.cleaned)
    }

    /// #232 (founder 2026-11-14): the name the others see in a game together
    /// and in a shared quiz's comparison: the typed one, else the Apple
    /// account's first name, else an automatic one in the interface language.
    /// The first automatic name is kept, so one person reads the same
    /// everywhere. Only a typed or account name lets a host start a game.
    func playerName(accountName: String?, languageCode: String? = Locale.interface.language.languageCode?.identifier) -> String {
        if let name = chosenName ?? Self.firstName(of: accountName) { return name }
        if let kept = defaults.string(forKey: Self.automaticKey).flatMap(Self.cleaned) { return kept }
        let name = Self.automaticName(languageCode: languageCode)
        defaults.set(name, forKey: Self.automaticKey)
        return name
    }

    /// The first word of the Apple account name ("Michal Kalis" → "Michal").
    static func firstName(of accountName: String?) -> String? {
        accountName?.split(separator: " ").first.flatMap { cleaned(String($0)) }
    }

    func save(_ name: String) {
        guard let name = Self.cleaned(name) else { return }
        defaults.set(name, forKey: key)
    }

    /// The trimmed name within the server's 1–24 characters, nil when empty.
    static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.prefix(scalars: maxLength)
    }

    /// An automatic guest name in the UI language, e.g. "Rýchly gepard".
    static func automaticName(languageCode: String?, pick: (Int) -> Int = { Int.random(in: 0 ..< $0) }) -> String {
        let names = switch languageCode {
        case "sk": skNames
        case "cs": csNames
        case "uk": ukNames
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
    private static let ukNames = [
        "Швидкий гепард", "Мудра сова", "Веселий дельфін", "Тиха лисиця",
        "Сміливий тигр", "Кмітлива білка", "Спокійний ведмідь", "Грайлива видра",
    ]
    private static let enNames = [
        "Swift Cheetah", "Wise Owl", "Happy Dolphin", "Quiet Fox",
        "Brave Tiger", "Clever Squirrel", "Calm Bear", "Playful Otter",
    ]
}
