//
//  CzechCommandGrammarTests.swift
//  HangsTests
//
//  #175 — the Czech command grammar, mirroring SlovakCommandGrammarTests
//  (TranscriberEngineTests.swift) case for case: the Czech set is built on the
//  same precision-over-recall design (mic open to the spoken language), so
//  every guarantee the Slovak set makes must hold for Czech too — including
//  the ř/ě/ů diacritics folding onto the same edit-distance floors.
//

import Foundation
import Testing
@testable import Hangs

@Suite("Czech command grammar (#175)")
struct CzechCommandGrammarTests {
    @Test("dictation-cs selection: cs_CZ locale, Czech grammar, dictation engine")
    func selectionMappings() {
        #expect(CommandEngineSelection.dictationCzech.localeIdentifier == "cs_CZ")
        #expect(CommandEngineSelection.dictationCzech.commandLanguage == .czech)
        #expect(CommandEngineSelection.dictationCzech.engineTag == "dictation")
        let adapter = CommandEngineSelection.dictationCzech.makeAdapter()
        #expect(adapter is DictationTranscriberCommandAdapter)
        #expect(adapter.locale.identifier == "cs_CZ")
        // Round-trips through the Settings picker like every other case.
        #expect(CommandEngineSelection(rawValue: "dictation-cs") == .dictationCzech)
    }

    @Test("dictation adapter biases the recognizer with the Czech spoken forms")
    func adapterDeclaresCzechVocabulary() {
        let czech = DictationTranscriberCommandAdapter(
            locale: Locale(identifier: "cs_CZ"), language: .czech
        )
        // Real diacritics — the recognizer is biased toward the SPOKEN forms;
        // folding is the matcher's job, not the engine's.
        #expect(czech.contextualStrings?.contains("přeskoč") == true)
        #expect(czech.contextualStrings?.contains("odpověz") == true)
        #expect(czech.contextualStrings?.contains("dál") == true)
        // Founder 2026-11-22: confirm and cancel are no commands, so the
        // recognizer must not be biased toward them.
        #expect(czech.contextualStrings?.contains("potvrď") != true)
        #expect(czech.contextualStrings?.contains("zruš") != true)
    }

    @Test("every Czech variant is stored pre-normalized (folded, lowercase)")
    func variantsAreNormalized() {
        for command in VoiceCommand.allCases {
            for variant in VoiceCommandLexicon.variants(for: command, language: .czech) {
                #expect(
                    VoiceCommandMatcher.normalize(variant) == variant,
                    "variant '\(variant)' must survive normalize unchanged"
                )
            }
        }
    }

    @Test("recall: each Czech command word routes on its screen, ř/ě/ů diacritics included")
    func czechCommandsRoute() {
        #expect(VoiceCommandMatcher.match(transcript: "Odpověz", on: .question, language: .czech) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "Další", on: .question, language: .czech) == .next)
        // The old words stay as hidden synonyms (muscle memory, #224).
        #expect(VoiceCommandMatcher.match(transcript: "Přeskoč", on: .question, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "vynech", on: .question, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "Zopakuj", on: .question, language: .czech) == .repeatQuestion)
        #expect(VoiceCommandMatcher.match(transcript: "opakuj", on: .question, language: .czech) == .repeatQuestion)
        #expect(VoiceCommandMatcher.match(transcript: "Dál", on: .noAnswer, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "dále", on: .noAnswer, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "Znovu", on: .confirmation, language: .czech) == .again)
    }

    /// WHY (founder 2026-11-22): confirm, stop, pause and cancel are gone —
    /// silence confirms, so on the sheet these words are filler or a new
    /// answer, never a command.
    @Test("removed Czech words are no command on the sheet")
    func czechRemovedWordsAreInert() {
        for word in ["potvrď", "ok", "Stop", "Pauza", "zruš", "domů"] {
            #expect(
                VoiceCommandMatcher.match(transcript: word, on: .confirmation, language: .czech) == nil,
                "'\(word)' must be no command"
            )
        }
    }

    @Test("screen scoping holds for Czech: a valid word on the wrong screen is inert")
    func czechScreenScoping() {
        #expect(VoiceCommandMatcher.match(transcript: "přeskoč", on: .confirmation, language: .czech) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "dál", on: .question, language: .czech) == nil)
        // "dále" / "dal" open "další" but are everyday words, not a skip (#224).
        #expect(VoiceCommandMatcher.match(transcript: "dále", on: .question, language: .czech) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "dal", on: .question, language: .czech) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "odpověz", on: .confirmation, language: .czech) == nil)
    }

    @Test("precision: Czech backchannels and particles never fire a command")
    func czechConversationIsInert() {
        // "jo" is THE Czech yes-word (#175 inherits the Slovak precision-over-
        // recall trade). Founder 2026-11-22: confirm is gone, so "ano"/"jo" are
        // filler on the sheet too — a reflexive yes must not become the answer.
        for phrase in ["jo", "ano", "dobře", "jasně", "no", "tak", "no tak", "jo jo", "ano ano", "tedy"] {
            for screen: VoiceCommandScreen in [.question, .noAnswer, .confirmation] {
                #expect(
                    VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .czech) == nil,
                    "'\(phrase)' must be inert on \(screen)"
                )
            }
        }
    }

    @Test("precision: ordinary Czech sentences are rejected by the content-token cap")
    func czechSentencesAreInert() {
        for phrase in ["to bylo dobrý", "pojď dál jedeme", "no tak to přeskočíme později", "dal jsem to tam"] {
            for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer] {
                #expect(
                    VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .czech) == nil,
                    "'\(phrase)' must be inert on \(screen)"
                )
            }
        }
    }

    @Test("strict next tolerates filler padding but not content words (Czech)")
    func czechStrictNext() {
        #expect(VoiceCommandMatcher.match(transcript: "no přeskoč", on: .question, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "jo, přeskoč", on: .question, language: .czech) == .next)
        // Content words remain → NOT a skip (it burns a freemium question).
        #expect(VoiceCommandMatcher.match(transcript: "přeskoč tuhle otázku", on: .question, language: .czech) == nil)
    }

    @Test("ambiguity margin: no two Czech commands on one screen collide")
    func czechVariantsAreDisjointPerScreen() {
        for screen: VoiceCommandScreen in [.question, .confirmation, .noAnswer] {
            for command in VoiceCommandLexicon.commands(on: screen) {
                for variant in VoiceCommandLexicon.variants(for: command, language: .czech) {
                    #expect(
                        VoiceCommandMatcher.match(transcript: variant, on: screen, language: .czech) == command,
                        "'\(variant)' must resolve to \(command) on \(screen), not be ambiguous"
                    )
                }
            }
        }
    }

    /// WHY: "again" has the most lenient floors (final 0.65, volatile 0.7), and
    /// only a FINAL gets the truncation credit: a half-heard "zno" (0.60 by edit
    /// distance) re-records from a final but not from a revisable volatile.
    @Test("volatile floor holds for Czech: a truncated word fires only from a final")
    func czechVolatileFloor() {
        #expect(VoiceCommandMatcher.match(transcript: "zno", on: .confirmation, isFinal: true, language: .czech) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "zno", on: .confirmation, isFinal: false, language: .czech) == nil)
    }

    @Test("driver-facing strings are Czech and quote the button words (#174)")
    func czechDisplayStrings() {
        #expect(VoiceCommandLexicon.hint(on: .question, language: .czech) == "Řekni „odpověz“ nebo „další“")
        #expect(VoiceCommandLexicon.hint(on: .confirmation, language: .czech) == "Řekni „znovu“ nebo novou odpověď")
        #expect(VoiceCommandLexicon.spokenWord(.answer, language: .czech) == "odpověz")
        #expect(VoiceCommandLexicon.spokenWord(.next, language: .czech) == "další")
        #expect(VoiceCommandLexicon.listeningCaption(language: .czech) == "POSLOUCHÁM PŘÍKAZY")
        #expect(VoiceCommandLexicon.listeningCaption(language: .czech, short: true) == "POSLOUCHÁM")
        // Founder 2026-11-22: no hint offers a word that is no command now.
        #expect(!VoiceCommandLexicon.hint(on: .confirmation, language: .slovak).contains("zruš"))
        #expect(!VoiceCommandLexicon.hint(on: .confirmation, language: .czech).contains("potvrď"))
    }
}
