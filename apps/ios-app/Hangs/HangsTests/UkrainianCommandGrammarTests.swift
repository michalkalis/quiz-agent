//
//  UkrainianCommandGrammarTests.swift
//  HangsTests
//
//  #231 — the Ukrainian command grammar, mirroring CzechCommandGrammarTests:
//  same precision-over-recall design, plus what Cyrillic adds. The words are
//  the ones Apple dictation (uk_UA) recognised on the Mac (2026-11-17), and
//  Cyrillic is never diacritic-folded: й and ї are letters of their own.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Ukrainian command grammar (#231)")
struct UkrainianCommandGrammarTests {
    @Test("dictation-uk selection: uk_UA locale, Ukrainian grammar, dictation engine")
    @MainActor
    func selectionMappings() {
        #expect(CommandEngineSelection.dictationUkrainian.localeIdentifier == "uk_UA")
        #expect(CommandEngineSelection.dictationUkrainian.commandLanguage == .ukrainian)
        #expect(CommandEngineSelection.dictationUkrainian.engineTag == "dictation")
        let adapter = CommandEngineSelection.dictationUkrainian.makeAdapter()
        #expect(adapter is DictationTranscriberCommandAdapter)
        #expect(adapter.locale.identifier == "uk_UA")
        #expect(CommandEngineSelection(rawValue: "dictation-uk") == .dictationUkrainian)
    }

    @Test("the dictation adapter biases the recognizer with the measured Ukrainian words")
    @MainActor
    func adapterDeclaresUkrainianVocabulary() {
        let ukrainian = DictationTranscriberCommandAdapter(locale: Locale(identifier: "uk_UA"), language: .ukrainian)
        for word in ["старт", "далі", "повтори", "пропусти", "ще раз", "добре", "стоп", "пауза", "додому"] {
            #expect(ukrainian.contextualStrings?.contains(word) == true, "'\(word)' is not in the bias list")
        }
    }

    @Test("every Ukrainian variant is stored pre-normalized (lowercase Cyrillic)")
    func variantsAreNormalized() {
        for command in VoiceCommand.allCases {
            for variant in VoiceCommandLexicon.variants(for: command, language: .ukrainian) {
                #expect(VoiceCommandMatcher.normalize(variant, language: .ukrainian) == variant, "'\(variant)'")
            }
        }
    }

    /// WHY: the nine words measured with Apple dictation must each do their job
    /// on their own screen, as the recognizer writes them (capital, full stop).
    @Test("recall: every measured command word routes on its screen")
    func measuredWordsRoute() {
        let cases: [(String, VoiceCommandScreen, VoiceCommand)] = [
            ("Старт", .question, .start), ("Повтори.", .question, .repeatQuestion), ("Пропусти", .question, .skip),
            ("Далі", .noAnswer, .next), ("Ще раз", .confirmation, .again), ("Добре.", .confirmation, .ok),
            ("Стоп", .confirmation, .stop), ("Пауза", .confirmation, .pause), ("Додому", .setEnd, .home),
            ("Відповідай", .question, .start),
        ]
        for (phrase, screen, expected) in cases {
            #expect(VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .ukrainian) == expected, "'\(phrase)' on \(screen)")
        }
    }

    /// WHY (#120 precision): the mic is open to the language being spoken.
    /// "так" and "добре" are what a Ukrainian conversation is made of; off the
    /// answer sheet they are filler and must never fire.
    @Test("backchannels are filler off the sheet")
    func backchannelsAreFiller() {
        for word in ["так", "Добре", "ну", "ага", "гаразд"] {
            for screen in [VoiceCommandScreen.question, .noAnswer, .error, .setEnd] {
                #expect(VoiceCommandMatcher.match(transcript: word, on: screen, language: .ukrainian) == nil, "'\(word)' on \(screen)")
            }
        }
        #expect(VoiceCommandMatcher.match(transcript: "Ну, пропусти", on: .question, language: .ukrainian) == .skip)
    }

    /// WHY (#231): й and ї are distinct letters. A Latin-style diacritic fold
    /// turns "бій" (fight) into "бии" and "їжак" into "іжак", merging words
    /// and breaking the lexicon.
    @Test("Cyrillic is lowercased, never diacritic-folded; an inner apostrophe keeps one word")
    func cyrillicNormalisation() {
        #expect(VoiceCommandMatcher.normalize("Бій", language: .ukrainian) == "бій")
        #expect(VoiceCommandMatcher.normalize("Бій", language: .ukrainian) != VoiceCommandMatcher.normalize("бий", language: .ukrainian))
        #expect(VoiceCommandMatcher.normalize("Їжак!", language: .ukrainian) == "їжак")
        // A recognizer may send й decomposed (и + combining breve).
        #expect(VoiceCommandMatcher.normalize("Бі\u{0438}\u{0306}", language: .ukrainian) == "бій")
        #expect(VoiceCommandMatcher.normalize("П'ять", language: .ukrainian) == "пять")
        #expect(VoiceCommandMatcher.normalize("Ще раз!", language: .ukrainian) == "щераз")
        // Latin keeps its old fold, in every language.
        #expect(VoiceCommandMatcher.normalize("Přeskoč", language: .czech) == "preskoc")
        #expect(VoiceCommandMatcher.normalize("don't", language: .english) == "don t")
    }

    /// WHY: "ні" (no) opens sentences; volatile it is the leading edge of a new
    /// answer, final it asks for the answer again.
    @Test("'ні' re-records on a final only; a sentence is a new answer")
    func noWaitsForFinal() {
        #expect(VoiceCommandMatcher.match(transcript: "ні", on: .confirmation, isFinal: false, language: .ukrainian) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "ні", on: .confirmation, isFinal: true, language: .ukrainian) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "Ні, це була Одеса", on: .confirmation, language: .ukrainian) == nil)
    }

    @Test("hints and captions speak Ukrainian with Ukrainian quotes")
    func display() {
        #expect(VoiceCommandLexicon.hint(on: .question, language: .ukrainian) == "Скажи «старт» або «пропусти»")
        #expect(VoiceCommandLexicon.spokenChips([.again], language: .ukrainian) == ["«ще раз»"])
        #expect(VoiceCommandLexicon.recognizingCaption(.skip, language: .ukrainian) == "«пропусти»…")
        #expect(VoiceCommandLexicon.listeningCaption(language: .ukrainian) == "СЛУХАЮ КОМАНДИ")
        #expect(SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [.again, .home], language: .ukrainian)
            == "Готово, 7 з 10 правильно. Скажи ще раз або додому.")
    }
}
