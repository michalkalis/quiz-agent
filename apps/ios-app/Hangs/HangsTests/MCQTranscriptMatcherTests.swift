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

    // MARK: - Ambiguous → nil

    @Test("Conflicting Slovak ordinals are ambiguous → nil")
    func ambiguousSlovak() {
        #expect(MCQTranscriptMatcher.match("jedna dva", options: options) == nil)
    }

    @Test("Two spoken values (English) are ambiguous → nil")
    func ambiguousEnglish() {
        #expect(MCQTranscriptMatcher.match("Mars or Jupiter", options: options) == nil)
    }

    @Test("Unrecognized utterance is no match → nil")
    func noMatch() {
        #expect(MCQTranscriptMatcher.match("neviem", options: options) == nil)
        #expect(MCQTranscriptMatcher.match("", options: options) == nil)
    }
}
