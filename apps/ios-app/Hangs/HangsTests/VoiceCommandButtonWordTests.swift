//
//  VoiceCommandButtonWordTests.swift
//  HangsTests
//
//  Founder 2026-10-13: "odpovedz" did not start the answer although the button
//  reads "Odpovedz". Whatever a button on a listening screen says must work by
//  voice, in every quiz language, even when the hint does not name the word.
//

import Foundation
@testable import Hangs
import Testing

/// One button title per quiz language, as `Localizable.xcstrings` renders it.
private struct ButtonTitle {
    let button: String
    let screen: VoiceCommandScreen
    let expected: VoiceCommand
    let sk: String
    let cs: String
    let en: String
    let uk: String

    func title(_ language: CommandLanguage) -> String {
        switch language {
        case .slovak: sk
        case .czech: cs
        case .english: en
        case .ukrainian: uk
        }
    }
}

private let buttonTitles: [ButtonTitle] = [
    ButtonTitle(button: "Answer", screen: .question, expected: .answer, sk: "Odpovedz", cs: "Odpověz", en: "Answer", uk: "Відповідай"),
    ButtonTitle(button: "Next (skip)", screen: .question, expected: .next, sk: "Ďalšia", cs: "Další", en: "Next", uk: "Пропусти"),
    ButtonTitle(button: "Again", screen: .confirmation, expected: .again, sk: "Znova", cs: "Znovu", en: "Again", uk: "Ще раз"),
    ButtonTitle(button: "Again", screen: .noAnswer, expected: .again, sk: "Znova", cs: "Znovu", en: "Again", uk: "Ще раз"),
    ButtonTitle(button: "Next (skip)", screen: .noAnswer, expected: .next, sk: "Ďalšia", cs: "Další", en: "Next", uk: "Пропусти"),
    // The empty-answer sheet's own Next button reads "Ďalej" / "Dál" / "Далі".
    ButtonTitle(button: "Next (sheet)", screen: .noAnswer, expected: .next, sk: "Ďalej", cs: "Dál", en: "Next", uk: "Далі"),
    ButtonTitle(button: "Try Again", screen: .error, expected: .again, sk: "Skús znova", cs: "Zkus znovu", en: "Try Again", uk: "Спробуй ще раз"),
    ButtonTitle(button: "Play Again", screen: .setEnd, expected: .again, sk: "Hraj znova", cs: "Hraj znovu", en: "Play Again", uk: "Зіграй ще раз"),
    // #243 decision 5: "home" is a command at the round end again, so its Home button's title is too.
    ButtonTitle(button: "Home", screen: .setEnd, expected: .home, sk: "Úvod", cs: "Úvod", en: "Home", uk: "Додому"),
]

private func title(_ button: String, on screen: VoiceCommandScreen) -> ButtonTitle {
    guard let found = buttonTitles.first(where: { $0.button == button && $0.screen == screen }) else {
        preconditionFailure("no button '\(button)' on \(screen)")
    }
    return found
}

@Suite("Button titles work as voice commands — sk / cs / en / uk")
struct VoiceCommandButtonWordTests {
    /// WHY: the driver reads the button and says it; a title the matcher does
    /// not know is a command that silently does nothing at the wheel.
    @Test("every button title fires its button's command", arguments: CommandLanguage.allCases)
    func everyTitleFires(_ language: CommandLanguage) {
        for button in buttonTitles {
            let title = button.title(language)
            for isFinal in [true, false] {
                #expect(
                    VoiceCommandMatcher.match(transcript: title, on: button.screen, isFinal: isFinal, language: language)
                        == button.expected,
                    "\(language) '\(title)' (\(button.button), final: \(isFinal)) must be \(button.expected) on \(button.screen)"
                )
            }
        }
    }

    /// WHY: sk/cs are recognized by the dictation engine, which is biased
    /// toward the words it is handed (#120).
    @Test("the recognizer is biased toward every button title", arguments: CommandLanguage.allCases)
    func vocabularyCoversEveryTitle(_ language: CommandLanguage) {
        let vocabulary = Set(
            VoiceCommandLexicon.contextualVocabulary(for: language)
                .map { VoiceCommandMatcher.normalize($0, language: language) }
        )
        for button in buttonTitles {
            let title = VoiceCommandMatcher.normalize(button.title(language), language: language)
            #expect(vocabulary.contains(title), "\(language) '\(title)' (\(button.button)) is not in the contextual vocabulary")
        }
    }

    /// WHY: button words are screen-scoped — "odpovedz" on the sheet must not
    /// start an answer, and the empty-answer sheet's "ďalej" / "dál" / "далі"
    /// are everyday words ("he gave", "go on") that must not skip a question,
    /// where a skip has no undo. (English "Next" is the question's word too.)
    @Test("a button word does nothing off its screen", arguments: CommandLanguage.allCases)
    func scopedToItsScreen(_ language: CommandLanguage) {
        let answer = title("Answer", on: .question).title(language)
        #expect(VoiceCommandMatcher.match(transcript: answer, on: .confirmation, language: language) == nil)
        guard language != .english else { return }
        let sheetNext = title("Next (sheet)", on: .noAnswer).title(language)
        #expect(VoiceCommandMatcher.match(transcript: sheetNext, on: .question, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: sheetNext, on: .confirmation, language: language) == nil)
    }

    /// WHY: joining "skús znova" into one word must not cost the sheet its
    /// "znova" — the retry titles mean "record again" there too.
    @Test("retry titles re-record on the sheet", arguments: CommandLanguage.allCases)
    func retryTitlesOnSheet(_ language: CommandLanguage) {
        let tryAgain = title("Try Again", on: .error).title(language)
        #expect(VoiceCommandMatcher.match(transcript: tryAgain, on: .confirmation, isFinal: true, language: language) == .again)
    }

    /// WHY: "try" / "play" / "skús" / "hraj" open the "Try Again" / "Hraj
    /// znova" titles but are everyday words; read as a truncated title they
    /// would restart the quiz from the error or set-end screen.
    @Test("a short word that opens a retry title does not retry", arguments: CommandLanguage.allCases)
    func shortHeadIsNotATitle(_ language: CommandLanguage) {
        let heads: [String] = switch language {
        case .english: ["try", "play"]
        case .slovak: ["skús", "hraj"]
        case .czech: ["zkus", "hraj"]
        case .ukrainian: []
        }
        for head in heads {
            for screen in [VoiceCommandScreen.error, .setEnd] {
                #expect(VoiceCommandMatcher.match(transcript: head, on: screen, isFinal: true, language: language) == nil, "\(language) '\(head)' on \(screen)")
            }
        }
    }

    /// WHY (#224): the skip button was renamed "Preskoč" → "Ďalšia" / "Next", but
    /// a driver with the old word in muscle memory must not find it dead.
    @Test("the old skip words still skip, as hidden synonyms", arguments: CommandLanguage.allCases)
    func oldSkipWordsStillWork(_ language: CommandLanguage) {
        let old: [String] = switch language {
        case .slovak: ["Preskoč", "vynechaj"]
        case .czech: ["Přeskoč", "vynech"]
        case .english: ["Skip", "pass"]
        case .ukrainian: ["Наступне", "наступна"]
        }
        for word in old {
            #expect(VoiceCommandMatcher.match(transcript: word, on: .question, language: language) == .next, "\(language) '\(word)'")
            #expect(VoiceCommandMatcher.match(transcript: word, on: .noAnswer, language: language) == .next, "\(language) '\(word)'")
        }
    }

    /// WHY (#224): hints and the recognizer bias list advertise the NEW word, and
    /// never the retired one (it would teach the driver the wrong habit).
    @Test("hints and spoken word carry the new skip word", arguments: CommandLanguage.allCases)
    func hintsUseTheNewWord(_ language: CommandLanguage) {
        let word = VoiceCommandLexicon.spokenWord(.next, language: language)
        #expect(word == title("Next (skip)", on: .question).title(language).lowercased())
        for screen in [VoiceCommandScreen.question, .noAnswer] {
            #expect(VoiceCommandLexicon.hint(on: screen, language: language).contains(word))
        }
    }
}
