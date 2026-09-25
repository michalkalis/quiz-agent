//
//  VoiceCommandLexiconParityTests.swift
//  HangsTests
//
//  #185 track D — the confirmation-sheet vocabulary (founder 5.3, 2026-09-24)
//  and the rule that EVERY lexicon change lands in sk / cs / en at once.
//
//  Car test 2026-09-23: commands had to be shouted, "nie, znova" was two
//  content words and never matched, "ešte raz" was not a word the app knew,
//  and "zruš" on the sheet threw the answer away. The founder's words:
//  "nie, zle, ešte raz, znova" = record again; "áno, hej, ok, potvrď" =
//  confirm; "stop" only holds the countdown; no voice cancel.
//

import Foundation
@testable import Hangs
import Testing

/// One founder intent, spoken in every quiz language. The initializer takes all
/// three, so an intent cannot be added for one language only.
private struct SpokenIntent {
    let name: String
    let screen: VoiceCommandScreen
    let expected: VoiceCommand
    let sk: String
    let cs: String
    let en: String

    func phrase(_ language: CommandLanguage) -> String {
        switch language {
        case .slovak: sk
        case .czech: cs
        case .english: en
        }
    }
}

private let sheetIntents: [SpokenIntent] = [
    SpokenIntent(name: "yes", screen: .confirmation, expected: .ok, sk: "Áno", cs: "Ano", en: "Yes"),
    SpokenIntent(name: "yeah", screen: .confirmation, expected: .ok, sk: "hej", cs: "jo", en: "yeah"),
    SpokenIntent(name: "ok", screen: .confirmation, expected: .ok, sk: "ok", cs: "ok", en: "ok"),
    SpokenIntent(name: "confirm", screen: .confirmation, expected: .ok, sk: "potvrď", cs: "potvrď", en: "confirm"),
    SpokenIntent(name: "yes, confirm", screen: .confirmation, expected: .ok, sk: "Áno, potvrď.", cs: "Ano, potvrď.", en: "Yes, confirm."),
    SpokenIntent(name: "no", screen: .confirmation, expected: .again, sk: "Nie.", cs: "Ne.", en: "No."),
    SpokenIntent(name: "wrong", screen: .confirmation, expected: .again, sk: "zle", cs: "špatně", en: "wrong"),
    SpokenIntent(name: "once more", screen: .confirmation, expected: .again, sk: "Ešte raz", cs: "Ještě jednou", en: "One more time"),
    SpokenIntent(name: "again", screen: .confirmation, expected: .again, sk: "znova", cs: "znovu", en: "again"),
    // The car-test utterance: two content words, both "record again".
    SpokenIntent(name: "no, again", screen: .confirmation, expected: .again, sk: "Nie, znova.", cs: "Ne, znovu.", en: "No, again."),
    SpokenIntent(name: "stop", screen: .confirmation, expected: .stop, sk: "Stop", cs: "Stop", en: "Stop"),
    SpokenIntent(name: "wait", screen: .confirmation, expected: .stop, sk: "počkaj", cs: "počkej", en: "wait"),
    SpokenIntent(name: "skip (no answer)", screen: .noAnswer, expected: .skip, sk: "preskoč", cs: "přeskoč", en: "skip"),
    SpokenIntent(name: "move on (no answer)", screen: .noAnswer, expected: .next, sk: "ďalej", cs: "dál", en: "next"),
    SpokenIntent(name: "again (no answer)", screen: .noAnswer, expected: .again, sk: "znova", cs: "znovu", en: "again"),
    SpokenIntent(name: "no (no answer)", screen: .noAnswer, expected: .again, sk: "nie", cs: "ne", en: "no"),
]

@Suite("#185 sheet vocabulary — sk / cs / en parity")
struct VoiceCommandLexiconParityTests {
    /// WHY: the founder's 5.3 words must work in the language the quiz is in —
    /// a lexicon change made for Slovak only would leave a Czech or English
    /// driver shouting again.
    @Test("every founder intent routes in every quiz language", arguments: CommandLanguage.allCases)
    func everyIntentInEveryLanguage(_ language: CommandLanguage) {
        for intent in sheetIntents {
            let phrase = intent.phrase(language)
            #expect(
                VoiceCommandMatcher.match(transcript: phrase, on: intent.screen, isFinal: true, language: language)
                    == intent.expected,
                "\(language) '\(phrase)' (\(intent.name)) must be \(intent.expected) on \(intent.screen)"
            )
        }
    }

    /// WHY: sk/cs run on the dictation engine, which is BIASED toward the
    /// words it is given (#120) — a command word missing from that list is a
    /// word the recognizer is less likely to produce in cabin noise.
    @Test("the recognizer is biased toward every sheet word", arguments: CommandLanguage.allCases)
    func vocabularyCoversEveryIntent(_ language: CommandLanguage) {
        let vocabulary = Set(
            VoiceCommandLexicon.contextualVocabulary(for: language)
                .map { VoiceCommandMatcher.normalize($0, language: language) }
        )
        for intent in sheetIntents {
            for word in VoiceCommandMatcher.normalize(intent.phrase(language), language: language).split(separator: " ") {
                #expect(vocabulary.contains(String(word)), "\(language) '\(word)' (\(intent.name)) is not in the contextual vocabulary")
            }
        }
    }

    /// WHY (founder 2026-09-24): voice cancel of an answer is not wanted —
    /// "zruš" threw the answer away with no undo. The Cancel BUTTON stays.
    /// Skip-undo keeps accepting the word: aborting a pending skip is the
    /// fail-safe direction.
    @Test("no voice cancel on the sheet, in any language", arguments: CommandLanguage.allCases)
    func noVoiceCancel(_ language: CommandLanguage) {
        let cancel = language == .english ? "cancel" : "zruš"
        #expect(VoiceCommandMatcher.match(transcript: cancel, on: .confirmation, language: language) == nil)
        #expect(VoiceCommandLexicon.isCancelWord(VoiceCommandMatcher.normalize(cancel), language: language))
        #expect(VoiceCommandLexicon.spokenWord(.stop, language: language) == "stop", "the hold word is 'stop'")
    }

    /// WHY: on the no-answer sheet confirming the empty field IS a skip, and in
    /// the car "potvrď" skipped the question there. The skip must be asked for.
    @Test("confirm words do nothing on the no-answer sheet", arguments: CommandLanguage.allCases)
    func confirmIsNotSkip(_ language: CommandLanguage) {
        for word in ["ok", language == .english ? "confirm" : "potvrď", language == .english ? "yes" : "ano"] {
            #expect(VoiceCommandMatcher.match(transcript: word, on: .noAnswer, language: language) == nil, "\(language) '\(word)'")
        }
    }

    /// WHY: "áno" / "yes" became commands on the SHEET only. On the result
    /// screen an "áno" would cut the explanation short, and on the question
    /// screen it must stay padding ("áno, preskoč" still skips).
    @Test("yes-words stay filler off the sheet", arguments: CommandLanguage.allCases)
    func yesWordsStayFillerElsewhere(_ language: CommandLanguage) {
        let yes = sheetIntents[0].phrase(language)
        #expect(VoiceCommandMatcher.match(transcript: yes, on: .result, language: language) == nil)
        let skip = language == .english ? "yeah, skip" : "\(sheetIntents[1].phrase(language)), \(language == .czech ? "přeskoč" : "preskoč")"
        #expect(VoiceCommandMatcher.match(transcript: skip, on: .question, language: language) == .skip, "\(language) '\(skip)'")
    }

    /// WHY (#119 intact): conversation always carries a word that is not a
    /// command, and two command words that disagree are not a command either —
    /// on the sheet such a sentence is a NEW answer (5.1), never a guess.
    @Test("sentences and disagreeing words are not commands", arguments: CommandLanguage.allCases)
    func sentencesAreNotCommands(_ language: CommandLanguage) {
        let sentences: [String] = switch language {
        case .slovak: ["Nie, to bol Paríž", "áno, znova", "nie áno"]
        case .czech: ["Ne, to byla Praha", "ano, znovu", "ne ano"]
        case .english: ["No, it was Paris", "yes, again", "no yes"]
        }
        for sentence in sentences {
            #expect(VoiceCommandMatcher.match(transcript: sentence, on: .confirmation, language: language) == nil, "'\(sentence)'")
        }
    }

    /// WHY: "nie" opens sentences, so a VOLATILE "nie" is usually the start of
    /// a new answer; only the final may call it a command. "znova" does not
    /// open sentences and must act early — it lost the race in the car.
    @Test("sentence-opening words wait for the final; 'again' words do not", arguments: CommandLanguage.allCases)
    func finalOnlyWords(_ language: CommandLanguage) {
        let no = language == .english ? "no" : (language == .czech ? "ne" : "nie")
        let again = language == .czech ? "znovu" : (language == .english ? "again" : "znova")
        #expect(VoiceCommandMatcher.match(transcript: no, on: .confirmation, isFinal: false, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: no, on: .confirmation, isFinal: true, language: language) == .again)
        #expect(VoiceCommandMatcher.match(transcript: again, on: .confirmation, isFinal: false, language: language) == .again)
        for word in VoiceCommandLexicon.finalOnlyVariants(for: language) {
            #expect(VoiceCommandLexicon.variants(for: .again, language: language).contains(word), "'\(word)' is a real variant")
        }
    }

    /// WHY (founder 2026-09-25): "no" means "record again" ONLY in an English
    /// quiz. In Slovak and Czech it is filler that often AGREES ("no jasné",
    /// "no, potvrď") — it must never throw an answer away there.
    @Test("'no' re-records in English only; in sk/cs it stays filler", arguments: CommandLanguage.allCases)
    func noIsAgainInEnglishOnly(_ language: CommandLanguage) {
        let bare = VoiceCommandMatcher.match(transcript: "No.", on: .confirmation, language: language)
        switch language {
        case .english:
            #expect(bare == .again)
        case .slovak, .czech:
            #expect(bare == nil, "\(language) 'no' is filler, not 'again'")
            #expect(VoiceCommandMatcher.match(transcript: "no, potvrď", on: .confirmation, language: language) == .ok)
            #expect(VoiceCommandMatcher.match(transcript: "no", on: .noAnswer, language: language) == nil)
            #expect(!VoiceCommandLexicon.variants(for: .again, language: language).contains("no"))
        }
    }

    /// WHY: the hint is the only place the sheet can say a new answer may simply
    /// be spoken (5.1), and the no-answer sheet must name ITS buttons.
    @Test("hints: the answer sheet invites a new answer, the no-answer sheet names again/skip", arguments: CommandLanguage.allCases)
    func hints(_ language: CommandLanguage) {
        let sheet = VoiceCommandLexicon.hint(on: .confirmation, language: language)
        #expect(sheet.contains(VoiceCommandLexicon.spokenWord(.again, language: language)))
        #expect(sheet.contains(sheetIntents[0].phrase(language).lowercased()), "names the yes-word")
        #expect(sheet.contains(sheetIntents[5].phrase(language).lowercased().trimmingCharacters(in: .punctuationCharacters)),
                "names the no-word")
        #expect(!sheet.contains("zruš") && !sheet.contains("cancel"))
        let noAnswer = VoiceCommandLexicon.hint(on: .noAnswer, language: language)
        #expect(noAnswer.contains(VoiceCommandLexicon.spokenWord(.again, language: language)))
        #expect(noAnswer.contains(VoiceCommandLexicon.spokenWord(.skip, language: language)))
        #expect(!noAnswer.contains(VoiceCommandLexicon.spokenWord(.ok, language: language)))
    }

    @Test("phrases join into one token and every joined token is a variant", arguments: CommandLanguage.allCases)
    func phrasesJoin(_ language: CommandLanguage) {
        for phrase in VoiceCommandLexicon.phrases(for: language) {
            #expect(VoiceCommandMatcher.normalize(phrase.words.joined(separator: " "), language: language) == phrase.token)
            #expect(VoiceCommandLexicon.variants(for: .again, language: language).contains(phrase.token))
        }
        // A lone "ešte" / "ještě" is still filler, not half a command.
        #expect(VoiceCommandMatcher.match(transcript: "ešte", on: .confirmation, language: .slovak) == nil)
    }
}
