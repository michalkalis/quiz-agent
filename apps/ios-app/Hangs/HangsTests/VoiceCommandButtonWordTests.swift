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

    func title(_ language: CommandLanguage) -> String {
        switch language {
        case .slovak: sk
        case .czech: cs
        case .english: en
        }
    }
}

private let buttonTitles: [ButtonTitle] = [
    ButtonTitle(button: "Start", screen: .home, expected: .start, sk: "Štart", cs: "Start", en: "Start"),
    ButtonTitle(button: "Answer", screen: .question, expected: .start, sk: "Odpovedz", cs: "Odpověz", en: "Answer"),
    ButtonTitle(button: "Skip", screen: .question, expected: .skip, sk: "Preskoč", cs: "Přeskoč", en: "Skip"),
    ButtonTitle(button: "Confirm", screen: .confirmation, expected: .ok, sk: "Potvrď", cs: "Potvrď", en: "Confirm"),
    ButtonTitle(button: "Again", screen: .confirmation, expected: .again, sk: "Znova", cs: "Znovu", en: "Again"),
    ButtonTitle(button: "Pause", screen: .confirmation, expected: .pause, sk: "Pauza", cs: "Pauza", en: "Pause"),
    ButtonTitle(button: "Again", screen: .noAnswer, expected: .again, sk: "Znova", cs: "Znovu", en: "Again"),
    ButtonTitle(button: "Skip", screen: .noAnswer, expected: .skip, sk: "Preskoč", cs: "Přeskoč", en: "Skip"),
    ButtonTitle(button: "Next", screen: .result, expected: .next, sk: "Ďalej", cs: "Dál", en: "Next"),
    ButtonTitle(button: "Try Again", screen: .error, expected: .again, sk: "Skús znova", cs: "Zkus znovu", en: "Try Again"),
    ButtonTitle(button: "Go Home", screen: .error, expected: .stop, sk: "Na úvod", cs: "Na úvod", en: "Go Home"),
    ButtonTitle(button: "Dismiss", screen: .error, expected: .stop, sk: "Zavri", cs: "Zavři", en: "Dismiss"),
    ButtonTitle(button: "Play Again", screen: .setEnd, expected: .again, sk: "Hraj znova", cs: "Hraj znovu", en: "Play Again"),
    ButtonTitle(button: "Home", screen: .setEnd, expected: .home, sk: "Úvod", cs: "Úvod", en: "Home"),
]

@Suite("Button titles work as voice commands — sk / cs / en")
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

    /// WHY: button words are screen-scoped — "odpovedz" on Home must not start
    /// a quiz, and "úvod" mid-question must not leave it.
    @Test("a button word does nothing off its screen", arguments: CommandLanguage.allCases)
    func scopedToItsScreen(_ language: CommandLanguage) {
        let answer = buttonTitles[1].title(language)
        let home = buttonTitles[13].title(language)
        #expect(VoiceCommandMatcher.match(transcript: answer, on: .home, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: home, on: .question, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: home, on: .confirmation, language: language) == nil)
    }

    /// WHY: joining "skús znova" into one word must not cost the sheet its
    /// "znova" — the retry titles mean "record again" there too.
    @Test("retry titles re-record on the sheet", arguments: CommandLanguage.allCases)
    func retryTitlesOnSheet(_ language: CommandLanguage) {
        let tryAgain = buttonTitles[9].title(language)
        #expect(VoiceCommandMatcher.match(transcript: tryAgain, on: .confirmation, isFinal: true, language: language) == .again)
    }

    /// WHY: "na" / "za" / "go" open the "Na úvod" / "Zavri" / "Go Home"
    /// titles but are everyday words; read as a truncated title they would
    /// abandon the quiz from the error or set-end screen.
    @Test("a short word that opens a title does not leave the screen", arguments: CommandLanguage.allCases)
    func shortHeadIsNotATitle(_ language: CommandLanguage) {
        let heads = language == .english ? ["go"] : ["na", "za", "No na!"]
        for head in heads {
            for screen in [VoiceCommandScreen.error, .setEnd] {
                #expect(VoiceCommandMatcher.match(transcript: head, on: screen, isFinal: true, language: language) == nil, "\(language) '\(head)' on \(screen)")
            }
        }
    }
}
