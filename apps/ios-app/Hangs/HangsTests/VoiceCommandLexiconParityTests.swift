//
//  VoiceCommandLexiconParityTests.swift
//  HangsTests
//
//  #185 track D — the confirmation-sheet vocabulary (founder 5.3, 2026-09-24)
//  and the rule that EVERY lexicon change lands in sk / cs / en / uk at once.
//
//  Car test 2026-09-23: commands had to be shouted, "nie, znova" was two
//  content words and never matched, "ešte raz" was not a word the app knew,
//  and "zruš" on the sheet threw the answer away. The founder's words:
//  "nie, zle, ešte raz, znova" = record again; no voice cancel. Founder
//  2026-11-22: the confirm words ("áno", "ok", "potvrď") and "stop" are gone,
//  silence confirms; "answer" and "next" are the other two words.
//

import Foundation
@testable import Hangs
import Testing

/// One founder intent, spoken in every quiz language. The initializer takes all
/// four, so an intent cannot be added for one language only.
private struct SpokenIntent {
    let name: String
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

private let sheetIntents: [SpokenIntent] = [
    SpokenIntent(name: "no", screen: .confirmation, expected: .again, sk: "Nie.", cs: "Ne.", en: "No.", uk: "Ні."),
    SpokenIntent(name: "wrong", screen: .confirmation, expected: .again, sk: "zle", cs: "špatně", en: "wrong", uk: "неправильно"),
    SpokenIntent(name: "once more", screen: .confirmation, expected: .again, sk: "Ešte raz", cs: "Ještě jednou", en: "One more time", uk: "Ще раз"),
    SpokenIntent(name: "again", screen: .confirmation, expected: .again, sk: "znova", cs: "znovu", en: "again", uk: "знову"),
    // The car-test utterance: two content words, both "record again".
    SpokenIntent(name: "no, again", screen: .confirmation, expected: .again, sk: "Nie, znova.", cs: "Ne, znovu.", en: "No, again.", uk: "Ні, ще раз."),
    // Founder 2026-11-22: the Answer button's word opens the answer.
    SpokenIntent(name: "answer", screen: .question, expected: .answer, sk: "odpovedz", cs: "odpověz", en: "answer", uk: "відповідай"),
    // #224: the button word, and the old words as hidden synonyms.
    SpokenIntent(name: "next (no answer)", screen: .noAnswer, expected: .next, sk: "ďalšia", cs: "další", en: "next", uk: "пропусти"),
    SpokenIntent(name: "old skip word (no answer)", screen: .noAnswer, expected: .next, sk: "preskoč", cs: "přeskoč", en: "skip", uk: "наступне"),
    // The empty-answer sheet's own Next button word (English reads "Next").
    SpokenIntent(name: "Next button (no answer)", screen: .noAnswer, expected: .next, sk: "ďalej", cs: "dál", en: "next", uk: "далі"),
    SpokenIntent(name: "again (no answer)", screen: .noAnswer, expected: .again, sk: "znova", cs: "znovu", en: "again", uk: "ще раз"),
    SpokenIntent(name: "no (no answer)", screen: .noAnswer, expected: .again, sk: "nie", cs: "ne", en: "no", uk: "ні"),
]

private func intent(_ name: String) -> SpokenIntent {
    guard let found = sheetIntents.first(where: { $0.name == name }) else { preconditionFailure("no intent '\(name)'") }
    return found
}

@Suite("#185 sheet vocabulary — sk / cs / en / uk parity")
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
    @Test("no voice cancel on the sheet, in any language", arguments: CommandLanguage.allCases)
    func noVoiceCancel(_ language: CommandLanguage) {
        let cancel = switch language {
        case .english: "cancel"
        case .slovak, .czech: "zruš"
        case .ukrainian: "скасуй"
        }
        #expect(VoiceCommandMatcher.match(transcript: cancel, on: .confirmation, language: language) == nil)
    }

    /// WHY (founder 2026-11-22): confirm is gone, so none of the old confirm
    /// words may do anything on either sheet. Filler ("áno", "ok") is noise,
    /// content ("potvrď", "yes") is a new answer: neither is a command, and
    /// on the no-answer sheet "potvrď" must still never skip the question.
    @Test("old confirm words do nothing on either sheet", arguments: CommandLanguage.allCases)
    func confirmWordsAreInert(_ language: CommandLanguage) {
        let words: [String] = switch language {
        case .slovak: ["Áno", "hej", "ok", "potvrď"]
        case .czech: ["Ano", "jo", "ok", "potvrď"]
        case .english: ["Yes", "yeah", "ok", "confirm"]
        case .ukrainian: ["Так", "добре", "ок", "підтверди"]
        }
        for word in words {
            for screen in [VoiceCommandScreen.confirmation, .noAnswer] {
                #expect(VoiceCommandMatcher.match(transcript: word, on: screen, language: language) == nil, "\(language) '\(word)' on \(screen)")
            }
        }
    }

    /// WHY: a backchannel is padding around a command ("hej, preskoč" still
    /// skips), never a command of its own.
    @Test("backchannels stay padding on the question screen", arguments: CommandLanguage.allCases)
    func backchannelsStayPadding(_ language: CommandLanguage) {
        let yeah: String = switch language {
        case .slovak: "hej"
        case .czech: "jo"
        case .english: "yeah"
        case .ukrainian: "добре"
        }
        let skip = "\(yeah), \(intent("old skip word (no answer)").phrase(language))"
        #expect(VoiceCommandMatcher.match(transcript: yeah, on: .question, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: skip, on: .question, language: language) == .next, "\(language) '\(skip)'")
    }

    /// WHY (#119 intact): conversation always carries a word that is not a
    /// command, and two command words that disagree are not a command either —
    /// on the sheet such a sentence is a NEW answer (5.1), never a guess.
    @Test("sentences and disagreeing words are not commands", arguments: CommandLanguage.allCases)
    func sentencesAreNotCommands(_ language: CommandLanguage) {
        let sentence: String = switch language {
        case .slovak: "Nie, to bol Paríž"
        case .czech: "Ne, to byla Praha"
        case .english: "No, it was Paris"
        case .ukrainian: "Ні, це був Київ"
        }
        #expect(VoiceCommandMatcher.match(transcript: sentence, on: .confirmation, language: language) == nil, "'\(sentence)'")
        // "again" and "next" are both commands on the no-answer sheet: they disagree.
        let disagree = "\(intent("again (no answer)").phrase(language)), \(intent("next (no answer)").phrase(language))"
        #expect(VoiceCommandMatcher.match(transcript: disagree, on: .noAnswer, language: language) == nil, "'\(disagree)'")
    }

    /// WHY: "nie" opens sentences, so a VOLATILE "nie" is usually the start of
    /// a new answer; only the final may call it a command. "znova" does not
    /// open sentences and must act early — it lost the race in the car.
    @Test("sentence-opening words wait for the final; 'again' words do not", arguments: CommandLanguage.allCases)
    func finalOnlyWords(_ language: CommandLanguage) {
        let no = intent("no (no answer)").phrase(language)
        let again = VoiceCommandLexicon.spokenWord(.again, language: language)
        #expect(VoiceCommandMatcher.match(transcript: no, on: .confirmation, isFinal: false, language: language) == nil)
        #expect(VoiceCommandMatcher.match(transcript: no, on: .confirmation, isFinal: true, language: language) == .again)
        #expect(VoiceCommandMatcher.match(transcript: again, on: .confirmation, isFinal: false, language: language) == .again)
        for word in VoiceCommandLexicon.finalOnlyVariants(for: language) {
            #expect(VoiceCommandLexicon.variants(for: .again, language: language).contains(word), "'\(word)' is a real variant")
        }
    }

    /// WHY (founder 2026-09-25): "no" means "record again" ONLY in an English
    /// quiz. In Slovak and Czech it is filler that often agrees ("no jasné") —
    /// it must never throw an answer away there; as padding it is just stripped.
    @Test("'no' re-records in English only; in sk/cs it stays filler", arguments: CommandLanguage.allCases)
    func noIsAgainInEnglishOnly(_ language: CommandLanguage) {
        let bare = VoiceCommandMatcher.match(transcript: "No.", on: .confirmation, language: language)
        switch language {
        case .english:
            #expect(bare == .again)
        case .ukrainian:
            // "ну" is the Ukrainian "no" particle: filler that often agrees.
            #expect(VoiceCommandMatcher.match(transcript: "Ну.", on: .confirmation, language: language) == nil)
            #expect(VoiceCommandMatcher.match(transcript: "ну, ще раз", on: .confirmation, language: language) == .again)
            #expect(VoiceCommandMatcher.match(transcript: "ну", on: .noAnswer, language: language) == nil)
        case .slovak, .czech:
            #expect(bare == nil, "\(language) 'no' is filler, not 'again'")
            let again = VoiceCommandLexicon.spokenWord(.again, language: language)
            #expect(VoiceCommandMatcher.match(transcript: "no, \(again)", on: .confirmation, language: language) == .again)
            #expect(VoiceCommandMatcher.match(transcript: "no", on: .noAnswer, language: language) == nil)
            #expect(!VoiceCommandLexicon.variants(for: .again, language: language).contains("no"))
        }
    }

    /// WHY (#189 founder 2026-09-29): the hint quotes "again" and never
    /// resurrects the removed voice cancel (#243.5: it no longer offers a new
    /// answer either); the no-answer sheet must name ITS buttons. Which words the confirmation hint
    /// quotes is covered by `confirmationHintQuotesButtonWords` below.
    @Test("hints: the answer sheet names again, the no-answer sheet names again/next", arguments: CommandLanguage.allCases)
    func hints(_ language: CommandLanguage) {
        let sheet = VoiceCommandLexicon.hint(on: .confirmation, language: language)
        #expect(sheet.contains(VoiceCommandLexicon.spokenWord(.again, language: language)))
        #expect(!sheet.contains("zruš") && !sheet.contains("cancel") && !sheet.contains("скасуй"))
        let noAnswer = VoiceCommandLexicon.hint(on: .noAnswer, language: language)
        #expect(noAnswer.contains(VoiceCommandLexicon.spokenWord(.again, language: language)))
        #expect(noAnswer.contains(VoiceCommandLexicon.spokenWord(.next, language: language)))
    }

    /// WHY (#189 founder feedback 2026-09-29, car test): the old wording ("say
    /// the answer again") never actually said the word "again", so the driver
    /// had nothing to repeat back. The hint must quote the word printed on the
    /// sheet's own Again button (Localizable.xcstrings) — a word not one of
    /// the sheet's own valid commands is a hint nobody can act on. Founder
    /// 2026-11-22: the sheet has no confirm word, so Again is the only one.
    @Test("confirmation hint quotes the again button word, a valid sheet command", arguments: CommandLanguage.allCases)
    func confirmationHintQuotesButtonWords(_ language: CommandLanguage) {
        let againButton: String = switch language {
        case .english: "again"
        case .slovak: "znova"
        case .czech: "znovu"
        case .ukrainian: "ще раз"
        }
        let hint = VoiceCommandLexicon.hint(on: .confirmation, language: language).lowercased()
        #expect(hint.contains(againButton), "\(language) hint must quote the button word '\(againButton)'")
        #expect(
            VoiceCommandMatcher.match(transcript: againButton, on: .confirmation, isFinal: true, language: language) != nil,
            "\(language) '\(againButton)' must be a valid confirmation-sheet command"
        )
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
