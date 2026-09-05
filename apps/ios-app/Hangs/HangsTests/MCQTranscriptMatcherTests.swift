//
//  MCQTranscriptMatcherTests.swift
//  HangsTests
//
//  Issue #45 task 45.2: the MCQ-voice path is the core functional gap for a
//  hands-free driving app — a driver must answer a multiple-choice question by
//  voice. These tests pin WHY each match strategy matters: a driver may say the
//  letter, the position (Slovak or English), or the answer itself, and an
//  ambiguous utterance must NOT be silently submitted as a wrong answer.
//
//  Precedence (2026-07-30 audit finding 1b, founder call): the answer TEXT
//  outranks a positional/letter directive, because on a counting question the
//  two vocabularies are the same words.
//

import Foundation
@testable import Hangs
import Testing

@Suite("MCQTranscriptMatcher")
struct MCQTranscriptMatcherTests {
    /// Largest-planet question: a→Mars, b→Jupiter, c→Saturn, d→Neptune.
    private let options: [(key: String, value: String)] = [
        ("a", "Mars"),
        ("b", "Jupiter"),
        ("c", "Saturn"),
        ("d", "Neptune"),
    ]

    /// "How many moons does Mars have?" — a counting question, where every answer
    /// TEXT is itself a number word and therefore collides with the positional
    /// vocabulary. Note no option value sits at its own position: "Two"→a (pos 1),
    /// "Three"→b (pos 2), "Four"→c (pos 3), "Five"→d (pos 4), so every test below
    /// distinguishes a value match from a positional one.
    private let countingOptions: [(key: String, value: String)] = [
        ("a", "Two"),
        ("b", "Three"),
        ("c", "Four"),
        ("d", "Five"),
    ]

    /// The same counting question rendered as digits — how a real generated MCQ
    /// usually looks. "4"→c (pos 3) and "5"→d (pos 4), so the answer 4 and the
    /// position 4 are different options.
    private let digitOptions: [(key: String, value: String)] = [
        ("a", "2"),
        ("b", "3"),
        ("c", "4"),
        ("d", "5"),
    ]

    // MARK: - Key letter

    @Test("Spoken option letter resolves to that key")
    func keyLetter() {
        #expect(MCQTranscriptMatcher.match("a", options: options) == "a")
        #expect(MCQTranscriptMatcher.match("B.", options: options) == "b")
    }

    // MARK: - Slovak letter-name / ordinal

    @Test("Slovak letter-name resolves to its key (diacritics folded)")
    func slovakLetterName() {
        #expect(MCQTranscriptMatcher.match("béčko", options: options) == "b")
        #expect(MCQTranscriptMatcher.match("becko", options: options) == "b")
    }

    @Test("Slovak ordinal resolves to option position")
    func slovakOrdinal() {
        #expect(MCQTranscriptMatcher.match("dva", options: options) == "b")
        #expect(MCQTranscriptMatcher.match("štyri", options: options) == "d")
    }

    // MARK: - English ordinal

    @Test("English ordinal / number resolves to option position")
    func englishOrdinal() {
        #expect(MCQTranscriptMatcher.match("two", options: options) == "b")
        #expect(MCQTranscriptMatcher.match("third", options: options) == "c")
    }

    // MARK: - Value match

    @Test("Spoken answer value resolves to its key")
    func valueMatch() {
        #expect(MCQTranscriptMatcher.match("Jupiter", options: options) == "b")
        #expect(MCQTranscriptMatcher.match("the answer is Jupiter", options: options) == "b")
    }

    // MARK: - Value beats position (audit 2026-07-30 finding 1b)

    /// The bug this precedence encodes: a matched key is submitted through the
    /// MCQ *fast path*, which skips the confirmation modal — so if "four" is read
    /// as "option 4" on a counting question, the driver silently loses the point
    /// to an answer they never said. The spoken answer text must win.
    @Test("Spoken number that is an answer TEXT resolves to that option, not that position")
    func valueBeatsPosition() {
        // "four" is the answer → key c; position 4 would be key d ("Five").
        #expect(MCQTranscriptMatcher.match("four", options: countingOptions) == "c")
        // Same collision in Slovak on an English-worded option set: "dva" has no
        // answer text to match, so it may still index position 2.
        #expect(MCQTranscriptMatcher.match("dva", options: countingOptions) == "b")
    }

    /// An utterance that is BOTH a value and a position: value wins (founder call,
    /// 2026-07-30). "two" is the answer text of option a, and also position 2 (b).
    @Test("Utterance that is both an answer value and a position resolves as the value")
    func valueWinsOverPositionCollision() {
        #expect(MCQTranscriptMatcher.match("two", options: countingOptions) == "a")
        #expect(MCQTranscriptMatcher.match("I think two", options: countingOptions) == "a")
    }

    /// Digit-rendered options: STT may commit "4" rather than "four". The digit is
    /// not in the positional vocabulary, so this pins that the value tier claims
    /// it — and that adding digits to `numberWords` later must not steal it.
    @Test("Digit answer text resolves to the option holding that digit")
    func digitValueMatch() {
        #expect(MCQTranscriptMatcher.match("4", options: digitOptions) == "c")
    }

    /// The canonical audit case: the option TEXT is a digit, the driver speaks the
    /// word. Word and digit are the same answer, so the value tier must bridge
    /// them — otherwise "four" falls through to the positional scan and the fast
    /// path submits option 4 ("5"), an answer the driver never gave.
    @Test("Spoken number word resolves to the option whose text is that digit")
    func numberWordMatchesDigitOptionText() {
        #expect(MCQTranscriptMatcher.match("four", options: digitOptions) == "c")
        #expect(MCQTranscriptMatcher.match("štyri", options: digitOptions) == "c")
        // Reverse rendering: the option text is the word, the driver's transcript
        // came through as a digit.
        let words: [(key: String, value: String)] = [("a", "Two"), ("b", "Three"), ("c", "Four"), ("d", "Five")]
        #expect(MCQTranscriptMatcher.match("4", options: words) == "c")
    }

    /// Descending options — value and position disagree for every option, so a
    /// positional read is guaranteed to be a wrong answer: "two" is option c.
    @Test("Number word beats position on descending digit options")
    func numberWordBeatsPositionDescending() {
        let descending: [(key: String, value: String)] = [("a", "4"), ("b", "3"), ("c", "2"), ("d", "1")]
        #expect(MCQTranscriptMatcher.match("two", options: descending) == "c")
        #expect(MCQTranscriptMatcher.match("dva", options: descending) == "c")
    }

    /// Hedging ("two or three") names two answers. Both bridge to a digit option,
    /// and the positional fallback is just as split, so the driver must get the
    /// confirmation modal instead of a coin flip.
    @Test("Two spoken numbers on digit options are ambiguous → nil")
    func ambiguousNumberWords() {
        #expect(MCQTranscriptMatcher.match("two or three", options: digitOptions) == nil)
    }

    // MARK: - Directives survive as the fallback

    /// Positional answering is the fallback, not dead: with no answer text spoken,
    /// an ordinal still indexes the option a driver pointed at.
    @Test("Positional directive still resolves when nothing matches an answer text")
    func positionalFallback() {
        #expect(MCQTranscriptMatcher.match("option two", options: options) == "b")
        #expect(MCQTranscriptMatcher.match("option fourth", options: options) == "d")
        // "the fourth one" stays ambiguous: "one" is a position word too, so the
        // driver gets the confirmation modal rather than a coin flip.
        #expect(MCQTranscriptMatcher.match("the fourth one", options: options) == nil)
    }

    /// Letter-name answering likewise: "céčko" names an option whose text ("Four")
    /// was never spoken, so the directive tier must still be reachable.
    @Test("Letter directive still resolves on a counting question")
    func letterFallbackOnCountingOptions() {
        #expect(MCQTranscriptMatcher.match("céčko", options: countingOptions) == "c")
        #expect(MCQTranscriptMatcher.match("d", options: countingOptions) == "d")
    }

    // MARK: - Ambiguous → nil

    @Test("Conflicting Slovak ordinals are ambiguous → nil")
    func ambiguousSlovak() {
        #expect(MCQTranscriptMatcher.match("jedna dva", options: options) == nil)
    }

    @Test("Two spoken values (English) are ambiguous → nil")
    func ambiguousEnglish() {
        #expect(MCQTranscriptMatcher.match("Mars or Jupiter", options: options) == nil)
    }

    /// A duplicated answer text can't be resolved by text alone. Rather than
    /// guessing between the two, the directive tier gets its turn — a driver who
    /// also said the letter has told us which one they meant.
    @Test("Ambiguous answer text falls back to a directive when one applies")
    func ambiguousValueFallsBackToDirective() {
        let duplicated: [(key: String, value: String)] = [
            ("a", "Mars"),
            ("b", "Jupiter"),
            ("c", "Mars"),
            ("d", "Neptune"),
        ]
        // "Mars" alone matches a and c → unresolvable, and no directive → nil.
        #expect(MCQTranscriptMatcher.match("Mars", options: duplicated) == nil)
        // With the letter spoken too, the directive disambiguates.
        #expect(MCQTranscriptMatcher.match("Mars, céčko", options: duplicated) == "c")
    }

    // MARK: - Tolerant value match (#171 Track I)

    /// WHY: Slovak declines its nouns, so the answer a driver actually says is
    /// almost never the nominative printed on the option ("Kocku dám", "s
    /// kockou"). Exact matching dropped every one of those to the raw-transcript
    /// sheet, where the backend's value-matching MCQ evaluator — no LLM
    /// fallback — graded a correct answer as wrong.
    @Test("Slovak declensions of the answer text resolve to that option")
    func slovakDeclensionResolves() {
        let shapes: [(key: String, value: String)] = [
            ("a", "Kocka"),
            ("b", "Guľa"),
            ("c", "Valec"),
            ("d", "Ihlan"),
        ]
        #expect(MCQTranscriptMatcher.match("kocku", options: shapes) == "a")
        #expect(MCQTranscriptMatcher.match("kockou", options: shapes) == "a")
        #expect(MCQTranscriptMatcher.match("myslím že kocka", options: shapes) == "a")
        #expect(MCQTranscriptMatcher.match("valcom", options: shapes) == "c")
    }

    /// WHY: STT near-misses are the other half of the same problem — one
    /// wrong character must not cost the point.
    @Test("A near-miss transcription of the answer text still resolves")
    func nearMissResolves() {
        #expect(MCQTranscriptMatcher.match("Jupitter", options: options) == "b")
        #expect(MCQTranscriptMatcher.match("Neptun", options: options) == "d")
    }

    /// WHY: tolerance must never turn ambiguity into a guess. If a loose form
    /// fits two options, the driver gets the sheet with the raw transcript —
    /// the same contract the exact tier already had.
    @Test("A tolerant match that fits two options stays ambiguous → nil")
    func tolerantAmbiguityStaysNil() {
        let similar: [(key: String, value: String)] = [
            ("a", "Karol"),
            ("b", "Karel"),
            ("c", "Ihlan"),
            ("d", "Valec"),
        ]
        #expect(MCQTranscriptMatcher.match("karola", options: similar) == nil)
    }

    /// WHY: the tolerant tier sits BELOW the exact value tier and ABOVE the
    /// directive tier, and must not steal either. Short option texts are
    /// excluded outright — at three characters a "near miss" is a different word.
    @Test("Tolerance does not steal short answer texts from the directive tier")
    func toleranceDoesNotStealDirectives() {
        // "dva" must still index position 2 on Two/Three/Four/Five, not fuzz
        // into "Two" or "Three".
        #expect(MCQTranscriptMatcher.match("dva", options: countingOptions) == "b")
        // A letter-name directive on the same set is likewise untouched.
        #expect(MCQTranscriptMatcher.match("céčko", options: countingOptions) == "c")
    }

    @Test("Unrecognized utterance is no match → nil")
    func noMatch() {
        #expect(MCQTranscriptMatcher.match("neviem", options: options) == nil)
        #expect(MCQTranscriptMatcher.match("", options: options) == nil)
    }
}
