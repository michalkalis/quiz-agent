//
//  VoiceCommandPhraseTests.swift
//  HangsTests
//
//  Voice commands have never worked reliably (founder, 2026-11). Two of the
//  causes are ours, not the recognizer's:
//   • people say "zopakuj otázku", "ďalšia otázka", "next question" — the
//     command plus the word for "question" — and the matcher, which allows
//     one content word, threw every such phrase away;
//   • the recognizer's bias list held backchannels ("áno", "hej", "nie") on
//     screens where they are not commands, nudging it toward the words that
//     must never fire there.
//

import Foundation
@testable import Hangs
import Testing

/// One natural phrase in every quiz language. The initializer takes all four,
/// so a phrase cannot be added for one language only.
private struct NaturalPhrase {
    let screen: VoiceCommandScreen
    let expected: VoiceCommand
    let sk: String
    let cs: String
    let en: String
    let uk: String

    func phrase(_ language: CommandLanguage) -> String {
        switch language {
        case .slovak: sk
        case .czech: cs
        case .english: en
        case .ukrainian: uk
        }
    }
}

private let questionPhrases: [NaturalPhrase] = [
    NaturalPhrase(screen: .question, expected: .repeatQuestion, sk: "Zopakuj otázku.", cs: "Zopakuj otázku.", en: "Repeat the question.", uk: "Повтори питання."),
    NaturalPhrase(screen: .question, expected: .repeatQuestion, sk: "zopakuj otázku", cs: "zopakuj otázku", en: "repeat question", uk: "повтори запитання"),
    NaturalPhrase(screen: .question, expected: .next, sk: "Ďalšia otázka.", cs: "Další otázka.", en: "Next question.", uk: "Наступне питання."),
    NaturalPhrase(screen: .question, expected: .next, sk: "Preskoč otázku", cs: "Přeskoč otázku", en: "Skip the question", uk: "Пропусти питання"),
    NaturalPhrase(screen: .question, expected: .next, sk: "ďalšiu otázku", cs: "další otázku", en: "skip question", uk: "пропусти запитання"),
    NaturalPhrase(screen: .noAnswer, expected: .next, sk: "Ďalšia otázka", cs: "Další otázka", en: "Next question", uk: "Наступне питання"),
]

@Suite("Voice commands — natural phrases and the per-screen bias list")
struct VoiceCommandPhraseTests {
    // MARK: - The word for "question"

    /// WHY: "zopakuj otázku" is how a person asks for the question again. It
    /// used to be two content words, so the matcher returned nothing and the
    /// driver concluded voice commands do not work.
    @Test("command + the word for 'question' routes in every language", arguments: CommandLanguage.allCases)
    func questionPhrasesRoute(_ language: CommandLanguage) {
        for intent in questionPhrases {
            let phrase = intent.phrase(language)
            #expect(
                VoiceCommandMatcher.match(transcript: phrase, on: intent.screen, isFinal: true, language: language) == intent.expected,
                "\(language) '\(phrase)' must be \(intent.expected) on \(intent.screen)"
            )
        }
    }

    /// WHY: the word for "question" is not a command. Said alone, or beside a
    /// command that has nothing to do with the question (answer, again), it
    /// must stay inert — on the answer sheet anything that is not a
    /// command is a new answer, and "nie, otázka" must not re-record one.
    @Test("the question word alone, or with an unrelated command, stays inert", arguments: CommandLanguage.allCases)
    func questionWordIsNotACommand(_ language: CommandLanguage) {
        let (word, answer, again, no) = switch language {
        case .slovak: ("otázka", "odpovedz otázka", "znova otázku", "nie, otázka")
        case .czech: ("otázka", "odpověz otázka", "znovu otázku", "ne, otázka")
        case .english: ("the question", "answer question", "again the question", "no, question")
        case .ukrainian: ("питання", "відповідай питання", "ще раз питання", "ні, питання")
        }
        for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer, .error, .setEnd] {
            #expect(VoiceCommandMatcher.match(transcript: word, on: screen, language: language) == nil, "\(language) '\(word)' on \(screen)")
        }
        #expect(VoiceCommandMatcher.match(transcript: answer, on: .question, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: again, on: .confirmation, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: no, on: .confirmation, language: language) == nil)
    }

    /// WHY: on the answer sheet only the sheet's own words are commands; a
    /// question phrase there is a new answer, never a skip.
    @Test("question phrases do nothing on the answer sheet", arguments: CommandLanguage.allCases)
    func questionPhrasesAreInertOnTheSheet(_ language: CommandLanguage) {
        for intent in questionPhrases {
            let phrase = intent.phrase(language)
            #expect(VoiceCommandMatcher.match(transcript: phrase, on: .confirmation, language: language) == nil, "\(language) '\(phrase)'")
        }
    }

    /// WHY: a sentence that merely talks about the question ("this question
    /// was hard") is conversation. Any other content word keeps it inert,
    /// exactly as before — the question word lifts the one-word cap by itself
    /// and nothing else.
    @Test("sentences about the question stay inert", arguments: CommandLanguage.allCases)
    func sentencesAboutTheQuestion(_ language: CommandLanguage) {
        let sentences: [String] = switch language {
        case .slovak: ["ďalšia otázka bude ťažká", "táto otázka bola ľahká", "zopakuj mi tú otázku prosím ťa"]
        case .czech: ["přeskoč tuhle otázku", "další otázka bude těžká", "ta otázka byla lehká"]
        case .english: ["can we skip the question", "the next question is hard", "repeat that question again"]
        case .ukrainian: ["наступне питання буде важке", "це питання було легке", "пропусти це питання"]
        }
        for sentence in sentences {
            for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer] {
                #expect(VoiceCommandMatcher.match(transcript: sentence, on: screen, language: language) == nil, "\(language) '\(sentence)' on \(screen)")
            }
        }
    }

    // MARK: - Per-screen bias list

    /// WHY: DictationTranscriber is biased toward the strings it is given
    /// (sk / cs / uk run on it). The sentence-opening "again" words ("nie",
    /// "zle") are commands on the answer sheet only; pulling the recognizer
    /// toward them on the question screen only nudges it toward a word we
    /// then ignore. The confirm backchannels ("áno", "hej") are no commands at
    /// all since 2026-11-22 and are biased for on no screen.
    @Test("sentence-opening words are biased for only on the answer sheet; confirm words nowhere")
    func backchannelsOnlyOnTheSheet() {
        let cases: [(CommandLanguage, [String], [String])] = [
            (.slovak, ["nie", "zle"], ["áno", "hej"]),
            (.czech, ["ne", "špatně"], ["ano", "jo"]),
            (.english, ["no", "wrong"], ["yes", "yeah"]),
            (.ukrainian, ["ні", "неправильно"], ["так", "добре"]),
        ]
        for (language, again, confirm) in cases {
            let question = VoiceCommandLexicon.contextualVocabulary(for: language, on: .question)
            let sheet = VoiceCommandLexicon.contextualVocabulary(for: language, on: .confirmation)
            for word in again {
                #expect(!question.contains(word), "\(language) '\(word)' is biased for on the question screen")
                #expect(sheet.contains(word), "\(language) '\(word)' is missing on the answer sheet")
            }
            for word in confirm {
                #expect(!sheet.contains(word), "\(language) '\(word)' is no command but is biased for on the sheet")
            }
        }
    }

    /// WHY: a word in the bias list that the matcher then ignores is pure
    /// dilution. Every entry must be a command on that screen.
    @Test("every biased word is a command on its screen", arguments: CommandLanguage.allCases)
    func everyBiasedWordActs(_ language: CommandLanguage) {
        for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer, .error, .setEnd] {
            for word in VoiceCommandLexicon.contextualVocabulary(for: language, on: screen) {
                #expect(
                    VoiceCommandMatcher.match(transcript: word, on: screen, isFinal: true, language: language) != nil,
                    "\(language) '\(word)' does nothing on \(screen)"
                )
            }
        }
    }

    /// WHY: the opposite failure — a command missing from its screen's list
    /// is a command the recognizer is less likely to hear in cabin noise.
    @Test("every command of a screen has its words in that screen's list", arguments: CommandLanguage.allCases)
    func everyCommandIsBiasedFor(_ language: CommandLanguage) {
        for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer, .error, .setEnd] {
            let heard = Set(
                VoiceCommandLexicon.contextualVocabulary(for: language, on: screen)
                    .compactMap { VoiceCommandMatcher.match(transcript: $0, on: screen, isFinal: true, language: language) }
            )
            for command in VoiceCommandLexicon.commands(on: screen) {
                #expect(heard.contains(command), "\(language) \(command) has no biased word on \(screen)")
            }
        }
    }

    /// WHY: Apple's limit for contextual strings is 100 phrases of one or two
    /// words; past it recognition of the list degrades.
    @Test("each screen's list stays within Apple's limits", arguments: CommandLanguage.allCases)
    func listStaysWithinLimits(_ language: CommandLanguage) {
        for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer, .error, .setEnd] {
            let list = VoiceCommandLexicon.contextualVocabulary(for: language, on: screen)
            #expect(!list.isEmpty && list.count <= 100)
            #expect(Set(list).count == list.count, "duplicates on \(screen)")
        }
    }

    /// WHY: the dictation adapter is what hands the list to the analyzer; it
    /// must hand over the screen's list, and SpeechTranscriber (which ignores
    /// contextual strings) still gets none.
    @Test("the dictation adapter hands over the screen's list")
    @MainActor
    func adapterUsesTheScreen() {
        let slovak = DictationTranscriberCommandAdapter(locale: Locale(identifier: "sk_SK"), language: .slovak)
        #expect(slovak.contextualStrings(on: .question) == VoiceCommandLexicon.contextualVocabulary(for: .slovak, on: .question))
        // "nie" is a command on the answer sheet only.
        #expect(slovak.contextualStrings(on: .question)?.contains("nie") == false)
        #expect(slovak.contextualStrings(on: .confirmation)?.contains("nie") == true)
        #expect(SpeechTranscriberCommandAdapter().contextualStrings(on: .question) == nil)
    }
}
