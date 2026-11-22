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
        for word in ["відповідай", "далі", "повтори", "пропусти", "ще раз"] {
            #expect(ukrainian.contextualStrings?.contains(word) == true, "'\(word)' is not in the bias list")
        }
        // Founder 2026-11-22: these are no commands any more, so no bias.
        for word in ["старт", "стоп", "пауза", "додому"] {
            #expect(ukrainian.contextualStrings?.contains(word) != true, "'\(word)' must not be biased")
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

    /// WHY: the words measured with Apple dictation must each do their job
    /// on their own screen, as the recognizer writes them (capital, full stop).
    @Test("recall: every measured command word routes on its screen")
    func measuredWordsRoute() {
        let cases: [(String, VoiceCommandScreen, VoiceCommand)] = [
            ("Відповідай", .question, .answer), ("Повтори.", .question, .repeatQuestion), ("Пропусти", .question, .next),
            ("Наступне", .question, .next), ("Далі", .noAnswer, .next), ("Ще раз", .confirmation, .again),
        ]
        for (phrase, screen, expected) in cases {
            #expect(VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .ukrainian) == expected, "'\(phrase)' on \(screen)")
        }
    }

    /// WHY (#120 precision): the mic is open to the language being spoken.
    /// "так" and "добре" are what a Ukrainian conversation is made of. Founder
    /// 2026-11-22: confirm is gone, so they are filler on every screen,
    /// the answer sheet included, and "ок" / "окей" with them.
    @Test("backchannels are filler on every screen")
    func backchannelsAreFiller() {
        for word in ["так", "Добре", "ну", "ага", "гаразд", "ок", "Окей"] {
            for screen in [VoiceCommandScreen.question, .noAnswer, .error, .setEnd, .confirmation] {
                #expect(VoiceCommandMatcher.match(transcript: word, on: screen, language: .ukrainian) == nil, "'\(word)' on \(screen)")
            }
        }
        #expect(VoiceCommandMatcher.match(transcript: "Ну, пропусти", on: .question, language: .ukrainian) == .next)
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

    /// WHY (PR #862 review): on the sheet the player may say a NEW answer, and
    /// «Правильно» ("right") is the natural Ukrainian confirm, «правда» /
    /// «неправда» the way the app asks true/false questions to be answered.
    /// One letter away from «неправильно» they re-recorded the answer: the
    /// opposite of what the player meant. The conversational words that act
    /// only on finals match exactly, never fuzzily or as a cut-off.
    @Test("«правильно», «правда», «неправда» and inflections of «добре» are answers, not commands")
    func nearConversationalWordsAreAnswers() {
        for word in ["Правильно.", "правильно", "Неправда.", "неправда", "Правда", "Добро", "Добра", "Доба", "Таки"] {
            for screen in [VoiceCommandScreen.confirmation, .noAnswer] {
                for isFinal in [true, false] {
                    #expect(VoiceCommandMatcher.match(transcript: word, on: screen, isFinal: isFinal, language: .ukrainian) == nil,
                            "'\(word)' on \(screen), final \(isFinal)")
                }
            }
        }
        // The exact words keep working. «Так» / «Добре» no longer confirm:
        // they are filler (founder 2026-11-22).
        #expect(VoiceCommandMatcher.match(transcript: "Неправильно.", on: .confirmation, language: .ukrainian) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "Ні", on: .noAnswer, language: .ukrainian) == .again)
    }

    /// WHY (PR #862 review): a short answer must not be taken for a command it
    /// shares letters with: «Дах» skipped as «далі». A Ukrainian word of four
    /// letters or fewer is usually another word one letter away (даль/далі), so
    /// a short command matches exactly. «далі» is the empty-answer sheet's Next.
    @Test("short answers one letter or a cut-off away from a command never fire it")
    func shortAnswersAreNotCommands() {
        for word in ["Да", "Дам", "Дар", "Дах", "Даль", "Дали"] {
            for isFinal in [true, false] {
                #expect(VoiceCommandMatcher.match(transcript: word, on: .noAnswer, isFinal: isFinal, language: .ukrainian) == nil,
                        "'\(word)' on noAnswer, final \(isFinal)")
            }
        }
    }

    /// WHY: the truncation credit exists for a command the recognizer cut off
    /// in cabin noise (#184). A cut-off of four letters or more keeps it.
    @Test("a genuinely cut-off long command still works on a final")
    func longCutOffStillWorks() {
        #expect(VoiceCommandMatcher.match(transcript: "Пропуст", on: .question, language: .ukrainian) == .next)
        // «Відпові» (0.70 by edit distance) earns the truncation credit on a
        // final only: a volatile hypothesis is held to answer's 0.8 floor.
        #expect(VoiceCommandMatcher.match(transcript: "Відпові", on: .question, language: .ukrainian) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "Відпові", on: .question, isFinal: false, language: .ukrainian) == nil)
    }

    /// WHY: a sentence answer opens with filler or a backchannel ("Ну, це
    /// Київ", "Так, це Львів"). The answer word is content, so the utterance is
    /// a new answer, never a confirm of the old one.
    @Test("answers padded with filler or a backchannel are not commands")
    func paddedAnswersAreNotCommands() {
        for answer in ["Ну, це Київ", "Так, це Львів", "Добре, Київ", "Ще Одеса", "це Київ", "Ну, ні, Харків"] {
            for screen in [VoiceCommandScreen.confirmation, .noAnswer] {
                #expect(VoiceCommandMatcher.match(transcript: answer, on: screen, language: .ukrainian) == nil, "'\(answer)' on \(screen)")
            }
        }
    }

    /// WHY (#231): й/ї are letters of their own. Folded to и/і, «Дали» ("they
    /// gave", with и) would read as «далі» and skip the question.
    @Test("й and ї are not merged with и and і")
    func shortIAndYiStayDistinct() {
        #expect(VoiceCommandMatcher.normalize("бій", language: .ukrainian) != VoiceCommandMatcher.normalize("бий", language: .ukrainian))
        #expect(VoiceCommandMatcher.normalize("Їжак", language: .ukrainian) != VoiceCommandMatcher.normalize("іжак", language: .ukrainian))
        #expect(VoiceCommandMatcher.normalize("Зіграй", language: .ukrainian) == "зіграй")
        #expect(VoiceCommandMatcher.match(transcript: "Дали", on: .noAnswer, language: .ukrainian) == nil)
    }

    /// WHY: recognizers and keyboards write the Ukrainian apostrophe three ways.
    /// «п'ять» must be one word however it is written, or "five" splits into
    /// "п" + "ять" and the answer stops being one token.
    @Test("apostrophe variants ʼ ’ ' give the same word, and it is an answer", arguments: ["'", "\u{2019}", "\u{02BC}"])
    func apostropheVariants(_ apostrophe: String) {
        #expect(VoiceCommandMatcher.normalize("П\(apostrophe)ять", language: .ukrainian) == "пять")
        #expect(VoiceCommandMatcher.normalize("дев\(apostrophe)ять", language: .ukrainian) == "девять")
        for word in ["П\(apostrophe)ять", "Дев\(apostrophe)ять"] {
            for screen in [VoiceCommandScreen.confirmation, .noAnswer] {
                #expect(VoiceCommandMatcher.match(transcript: word, on: screen, language: .ukrainian) == nil, "'\(word)' on \(screen)")
            }
        }
    }

    @Test("hints and captions speak Ukrainian with Ukrainian quotes")
    func display() {
        #expect(VoiceCommandLexicon.hint(on: .question, language: .ukrainian) == "Скажи «відповідай» або «пропусти»")
        #expect(VoiceCommandLexicon.spokenChips([.again], language: .ukrainian) == ["«ще раз»"])
        #expect(VoiceCommandLexicon.recognizingCaption(.next, language: .ukrainian) == "«пропусти»…")
        #expect(VoiceCommandLexicon.listeningCaption(language: .ukrainian) == "СЛУХАЮ КОМАНДИ")
        #expect(SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [.again], language: .ukrainian)
            == "Готово, 7 з 10 правильно. Скажи ще раз.")
    }

    /// WHY: the app runs from iOS 26, and a device whose dictation lacks
    /// uk_UA must degrade like sk / cs do: commands off (the buttons stay),
    /// no download attempt, no crash. On the iOS 26.5 and 27.0 simulators
    /// DictationTranscriber lists uk-UA (2026-11-18), so this is the fallback.
    @Test("no uk_UA in the dictation engine: commands are off and nothing downloads")
    @MainActor
    func unsupportedLocaleTurnsCommandsOff() async {
        let service = SilenceDetectionService(engine: NoUkrainianDictation(), selection: .dictationUkrainian)
        await service.prepareAssets()
        guard case .unavailable = service.commandAvailability else {
            Issue.record("commands are \(service.commandAvailability) without uk_UA")
            return
        }
    }
}

/// A dictation engine without Ukrainian, as an older or trimmed iOS reports it.
@MainActor
private final class NoUkrainianDictation: CommandTranscriberAdapter {
    nonisolated let engineTag = "dictation"
    nonisolated let locale = Locale(identifier: "uk_UA")
    var contextualStrings: [String]? { nil }

    func supportedLocales() async -> [Locale] { [Locale(identifier: "en_US"), Locale(identifier: "sk_SK")] }
    func installedLocales() async -> [Locale] { [] }
    func installAssets() async throws { Issue.record("an unsupported locale must not download") }
    func makeSession() -> CommandTranscriberSession {
        DictationTranscriberCommandAdapter(locale: locale, language: .ukrainian).makeSession()
    }
}
