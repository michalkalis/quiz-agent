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
    /// Matching is attempted in three tiers. The transcript is matched against
    /// the option *values* first — what the driver said the answer **is**
    /// outranks how the option could be indexed — exactly, then tolerantly
    /// (#171 Track I: Slovak declines its nouns, so a driver saying "kocku" for
    /// the option "Kocka" must still land on it). Only when neither yields a
    /// unique option does a *directive* (an option letter, a Slovak/English
    /// letter-name, or an ordinal/number word) resolve the choice. Every tier
    /// returns a key only when it identifies exactly one option — zero matches
    /// or conflicting matches resolve to `nil`, and the caller shows the
    /// confirmation sheet with the raw transcript instead of guessing.
    ///
    /// - Parameters:
    ///   - transcript: the raw committed transcript from STT.
    ///   - options: ordered options, typically `Question.sortedAnswerOptions`.
    /// - Returns: the matched option key, or `nil` when ambiguous / no match.
    static func match(_ transcript: String, options: [(key: String, value: String)]) -> String? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty, !options.isEmpty else { return nil }

        let tokens = normalized.split(separator: " ").map(String.init)

        // A counting question renders its answers as digits ("4") while STT
        // commits the word ("four" / "štyri") — or the reverse. Both are the same
        // *answer*, so the value tier below must see them as one. Reuses
        // `numberWords`, and bridges only word↔digit, never word↔word: an ordinal
        // like "second" therefore still reads as a position rather than as the
        // option whose text is "Two".
        var spokenAsDigits = Set<String>() // "four" → "4"
        var spokenDigits = Set<Int>() // "4" → 4
        for token in tokens {
            if let number = numberWords[token] { spokenAsDigits.insert(String(number)) }
            if let digit = Int(token) { spokenDigits.insert(digit) }
        }

        // Tier 1 — value match: the answer text spoken (with optional filler).
        // Deliberately ahead of the directive scan (2026-07-30 audit finding 1b,
        // founder call): on a counting question the answer text *is* a number
        // word, so the positional vocabulary would claim "štyri" as "option 4"
        // and the no-confirmation MCQ fast path would submit the wrong option
        // without the driver ever seeing it.
        let padded = " \(normalized) "
        var values = Set<String>()
        for option in options {
            let value = normalize(option.value)
            guard !value.isEmpty else { continue }
            if normalized == value || padded.contains(" \(value) ") {
                values.insert(option.key)
            } else if spokenAsDigits.contains(value) {
                values.insert(option.key)
            } else if let number = numberWords[value], spokenDigits.contains(number) {
                values.insert(option.key)
            }
        }
        if values.count == 1 { return values.first }

        // Tier 1.5 — tolerant value match (#171 Track I). Exact matching loses
        // every inflected form, and Slovak/Czech inflect the answer text the
        // moment it is spoken in a sentence ("kocku", "kockou"), as does a
        // near-miss from STT. Without this the driver's spoken answer reached
        // the backend as raw text, where the MCQ evaluator — a value match with
        // no LLM fallback — graded it wrong. Short values (< 4 characters) are
        // excluded: at that length a stem or an edit-distance neighbour is noise
        // ("two" vs "tri"), and their exact match already ran above.
        var tolerant = Set<String>()
        for option in options {
            let value = normalize(option.value)
            guard value.count >= 4 else { continue }
            if value.contains(" ") {
                if similarity(normalized, value) >= fuzzyThreshold { tolerant.insert(option.key) }
            } else if tokens.contains(where: { matchesInflected($0, value) }) {
                tolerant.insert(option.key)
            }
        }
        if tolerant.count == 1 { return tolerant.first }

        // Tier 2 — directives: explicit letter / letter-name / ordinal. Reached
        // only when the value tier found no *unique* option (nothing spoken that
        // matches an answer text, or two options sharing it), so "béčko" and
        // "option two" keep working.
        let keysByNorm = Dictionary(options.map { (normalize($0.key), $0.key) }) { first, _ in first }
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
        return directive.count == 1 ? directive.first : nil
    }

    /// Normalized edit distance above which two words are "the same answer".
    private static let fuzzyThreshold = 0.85

    /// Does `token` read as an inflected / mis-transcribed form of `value`?
    /// Two independent signals, because they catch different failures:
    /// a near-miss from STT keeps the word length (edit distance), while a
    /// Slovak/Czech declension rewrites only the ENDING and can move the
    /// similarity well below the threshold ("kockou" vs "kocka" scores 0.67).
    ///
    /// The stem test therefore asks for a shared prefix that is both long
    /// enough to be a word (≥ 3) and most of the shorter word (≥ 60 %), with
    /// only a short ending left over on each side — the shape of a declension
    /// ("valec"/"valcom"), not of two different words ("neviem"/"neptune").
    private static func matchesInflected(_ token: String, _ value: String) -> Bool {
        guard token.count >= 4 else { return false }
        if similarity(token, value) >= fuzzyThreshold { return true }
        let stem = commonPrefixLength(token, value)
        let shorter = min(token.count, value.count)
        return stem >= 3
            && Double(stem) >= 0.6 * Double(shorter)
            && token.count - stem <= 3
            && value.count - stem <= 3
    }

    /// 1 − (Levenshtein distance / longer length): 1.0 identical, 0.0 unrelated.
    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let longer = max(lhs.count, rhs.count)
        guard longer > 0 else { return 1.0 }
        return 1.0 - Double(editDistance(lhs, rhs)) / Double(longer)
    }

    /// Iterative Levenshtein over one rolling row — the strings here are single
    /// spoken answers, so the quadratic work is a few hundred comparisons.
    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0 ... b.count)
        for i in 1 ... a.count {
            var previous = row[0]
            row[0] = i
            for j in 1 ... b.count {
                let insertOrDelete = min(row[j] + 1, row[j - 1] + 1)
                let substitute = previous + (a[i - 1] == b[j - 1] ? 0 : 1)
                previous = row[j]
                row[j] = min(insertOrDelete, substitute)
            }
        }
        return row[b.count]
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        zip(lhs, rhs).prefix { $0 == $1 }.count
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
