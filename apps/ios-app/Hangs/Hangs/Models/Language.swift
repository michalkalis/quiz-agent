//
//  Language.swift
//  Hangs
//
//  Language model for quiz localization
//

import Foundation

/// Supported quiz languages
struct Language: Identifiable, Hashable, Sendable {
    let id: String // ISO 639-1 code (e.g., "sk", "en", "cs")
    let name: String // English name (e.g., "Slovak")
    let nativeName: String // Native language name (e.g., "Slovenčina")

    /// All supported languages
    /// OpenAI TTS supports ~99 languages - add more as needed
    static let supportedLanguages: [Language] = [
        Language(id: "en", name: String(localized: "English", comment: "Language name: English"), nativeName: "English"),
        Language(id: "sk", name: String(localized: "Slovak", comment: "Language name: Slovak"), nativeName: "Slovenčina"),
        Language(id: "cs", name: String(localized: "Czech", comment: "Language name: Czech"), nativeName: "Čeština"),
        Language(id: "de", name: String(localized: "German", comment: "Language name: German"), nativeName: "Deutsch"),
        Language(id: "fr", name: String(localized: "French", comment: "Language name: French"), nativeName: "Français"),
        Language(id: "es", name: String(localized: "Spanish", comment: "Language name: Spanish"), nativeName: "Español"),
        Language(id: "it", name: String(localized: "Italian", comment: "Language name: Italian"), nativeName: "Italiano"),
        Language(id: "pl", name: String(localized: "Polish", comment: "Language name: Polish"), nativeName: "Polski"),
        Language(id: "hu", name: String(localized: "Hungarian", comment: "Language name: Hungarian"), nativeName: "Magyar"),
        Language(id: "ro", name: String(localized: "Romanian", comment: "Language name: Romanian"), nativeName: "Română"),
    ]

    /// Default language (English)
    static let `default` = supportedLanguages[0]

    /// Find language by ISO code
    /// - Parameter code: ISO 639-1 language code
    /// - Returns: Language if found, nil otherwise
    static func forCode(_ code: String) -> Language? {
        supportedLanguages.first(where: { $0.id == code })
    }
}
