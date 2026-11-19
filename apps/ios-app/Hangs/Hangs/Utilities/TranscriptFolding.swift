//
//  TranscriptFolding.swift
//  Hangs
//
//  #231: the normalisation of the on-device command matcher
//  (`VoiceCommandMatcher`). Latin is lowercased and
//  diacritic-folded exactly as before ("Štyri" → "styri"). Cyrillic is only
//  lowercased: in Ukrainian й, ї and є are letters of their own, and folding
//  them (й → и, ї → і) would merge different words ("бій" fight, "бий" hit).
//

import Foundation

nonisolated enum TranscriptFolding {
    /// Lowercased tokens separated by single spaces where any non-alphanumeric
    /// run was. An apostrophe inside a Cyrillic word is dropped instead
    /// ("п'ять" → "пять"), so the word stays one token.
    static func fold(_ string: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previousWasCyrillic = false
        // Precomposed first: a recognizer may deliver "й" as и + combining breve.
        for character in string.precomposedStringWithCanonicalMapping {
            if let first = character.unicodeScalars.first, isCyrillic(first) {
                scalars.append(contentsOf: String(character).lowercased().unicodeScalars)
                previousWasCyrillic = true
                continue
            }
            if previousWasCyrillic, apostrophes.contains(character) { continue }
            previousWasCyrillic = false
            let folded = String(character).folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            for scalar in folded.unicodeScalars {
                scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
            }
        }
        return String(scalars)
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}"]

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400 ... 0x04FF).contains(scalar.value)
    }
}
