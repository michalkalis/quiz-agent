//
//  MCQTranscriptMatcher.swift
//  Hangs
//
//  Issue #45 task 45.2: pure value type that maps a committed STT transcript to
//  a multiple-choice option key (or nil). This is the heart of the MCQ-voice
//  path — a hands-free driving app must let a driver answer a multiple-choice
//  question by speaking the letter ("béčko"), the position ("dva" / "two"), or
//  the answer text itself ("Jupiter"). Ambiguity must resolve to nil so the
//  caller can re-record rather than submit a wrong answer (45.3 wires this up).
//

import Foundation

/// Resolves a committed transcript against an ordered list of MCQ options.
enum MCQTranscriptMatcher {
    /// Maps `transcript` to the key of a single matching option.
    ///
    /// Matching is attempted in two tiers. A *directive* spoken by the driver
    /// (an option letter, a Slovak/English letter-name, or an ordinal/number
    /// word) is resolved first; if no directive is present the transcript is
    /// matched against the option values. Either tier returns a key only when
    /// it identifies exactly one option — zero matches or conflicting matches
    /// resolve to `nil`.
    ///
    /// - Parameters:
    ///   - transcript: the raw committed transcript from STT.
    ///   - options: ordered options, typically `Question.sortedAnswerOptions`.
    /// - Returns: the matched option key, or `nil` when ambiguous / no match.
    static func match(_ transcript: String, options: [(key: String, value: String)]) -> String? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty, !options.isEmpty else { return nil }

        let tokens = normalized.split(separator: " ").map(String.init)
        let keysByNorm = Dictionary(options.map { (normalize($0.key), $0.key) }) { first, _ in first }

        // Tier 1 — directives: explicit letter / letter-name / ordinal.
        var directive = Set<String>()
        for token in tokens {
            if let key = keysByNorm[token] {
                directive.insert(key)
            }
            if let letter = letterNames[token], let key = keysByNorm[letter] {
                directive.insert(key)
            }
            if let position = numberWords[token], position >= 1, position <= options.count {
                directive.insert(options[position - 1].key)
            }
        }
        if !directive.isEmpty {
            return directive.count == 1 ? directive.first : nil
        }

        // Tier 2 — value match: the full answer text spoken (with optional filler).
        let padded = " \(normalized) "
        var values = Set<String>()
        for option in options {
            let value = normalize(option.value)
            guard !value.isEmpty else { continue }
            if normalized == value || padded.contains(" \(value) ") {
                values.insert(option.key)
            }
        }
        return values.count == 1 ? values.first : nil
    }

    /// Lowercase, diacritic-fold (`štyri`→`styri`, `béčko`→`becko`), and reduce
    /// every non-alphanumeric run to a single space so STT punctuation/casing
    /// and Slovak diacritics don't defeat the lookup tables below.
    private static func normalize(_ string: String) -> String {
        let folded = string.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Normalized letter-names → option key letter. Slovak `áčko/béčko/céčko/déčko`
    /// and the short `bé/cé/dé` forms; `áčko` folds to `acko`, etc.
    private static let letterNames: [String: String] = [
        "acko": "a",
        "becko": "b", "be": "b",
        "cecko": "c", "ce": "c",
        "decko": "d", "de": "d",
    ]

    /// Normalized number / ordinal words → 1-based option position (SK + EN).
    private static let numberWords: [String: Int] = [
        "one": 1, "first": 1, "jedna": 1, "jeden": 1, "prva": 1, "prvy": 1, "prve": 1,
        "two": 2, "second": 2, "dva": 2, "dve": 2, "druha": 2, "druhy": 2, "druhe": 2,
        "three": 3, "third": 3, "tri": 3, "tretia": 3, "treti": 3, "tretie": 3,
        "four": 4, "fourth": 4, "styri": 4, "stvrta": 4, "stvrty": 4, "stvrte": 4,
    ]
}
