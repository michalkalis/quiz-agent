//
//  Language.swift
//  Hangs
//
//  Language model for quiz localization
//

import Foundation

/// Supported quiz languages
struct Language: Identifiable, Hashable, Sendable {
    let id: String  // ISO 639-1 code (e.g., "sk", "en", "cs")
    let name: String  // English name (e.g., "Slovak")
    let nativeName: String  // Native language name (e.g., "Slovenčina")

    /// All supported languages
    /// OpenAI TTS supports ~99 languages - add more as needed
    static let supportedLanguages: [Language] = [
        // `name` is the English exonym shown in the language picker subtitle → localized.
        // `nativeName` is each language's own name (same in any UI) → kept verbatim, never localized.
        Language(id: "en", name: String(localized: "English", comment: "Language name (exonym)"), nativeName: "English"),
        Language(id: "sk", name: String(localized: "Slovak", comment: "Language name (exonym)"), nativeName: "Slovenčina"),
        Language(id: "cs", name: String(localized: "Czech", comment: "Language name (exonym)"), nativeName: "Čeština"),
        Language(id: "de", name: String(localized: "German", comment: "Language name (exonym)"), nativeName: "Deutsch"),
        Language(id: "fr", name: String(localized: "French", comment: "Language name (exonym)"), nativeName: "Français"),
        Language(id: "es", name: String(localized: "Spanish", comment: "Language name (exonym)"), nativeName: "Español"),
        Language(id: "it", name: String(localized: "Italian", comment: "Language name (exonym)"), nativeName: "Italiano"),
        Language(id: "pl", name: String(localized: "Polish", comment: "Language name (exonym)"), nativeName: "Polski"),
        Language(id: "hu", name: String(localized: "Hungarian", comment: "Language name (exonym)"), nativeName: "Magyar"),
        Language(id: "ro", name: String(localized: "Romanian", comment: "Language name (exonym)"), nativeName: "Română")
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

// MARK: - Servable subset (#168 DD14/DD15)

/// `supportedLanguages` above is the DISPLAY catalogue — how a code is named.
/// What the pickers may OFFER is a server-owned subset (`LanguageAvailability`),
/// because a language only becomes offerable once its translated corpus is
/// approved. Keeping the two apart means re-enabling a language is an env flip
/// on a running deploy, not a new build.
extension Language {
    /// Quiz languages the user may pick (Home + Settings pickers).
    static var selectableLanguages: [Language] {
        selectableLanguages(in: LanguageAvailability.shared.quizCodes)
    }

    /// Languages a custom pack may be ordered in — a narrower list, since packs
    /// are still generated in English and merely stamped with the code (DD15).
    static var packOrderLanguages: [Language] {
        selectableLanguages(in: LanguageAvailability.shared.packOrderCodes)
    }

    /// The display catalogue filtered to `codes`, in catalogue order so the
    /// menu ordering never depends on how the server happened to sort its list.
    static func selectableLanguages(in codes: [String]) -> [Language] {
        let allowed = Set(codes)
        let filtered = supportedLanguages.filter { allowed.contains($0.id) }
        // A server list that names nothing we can display would empty the menu;
        // showing the default beats showing an unusable picker.
        return filtered.isEmpty ? [Language.default] : filtered
    }

    /// Resolve a *stored* quiz-language preference for use. A code that is no
    /// longer offered (hidden between launches, or hidden by a refresh
    /// mid-session) degrades to `Language.default` — sending it would 422 once
    /// the backend validators harden (T26).
    static func selectable(_ code: String) -> Language {
        selectable(code, in: selectableLanguages)
    }

    static func selectable(_ code: String, in languages: [Language]) -> Language {
        languages.first(where: { $0.id == code }) ?? Language.default
    }
}
