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
        #expect(czech.contextualStrings?.contains("potvrď") == true)
        #expect(czech.contextualStrings?.contains("dál") == true)
        #expect(czech.contextualStrings?.contains("zruš") == true)
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
        #expect(VoiceCommandMatcher.match(transcript: "Start", on: .home, language: .czech) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "Přeskoč", on: .question, language: .czech) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "vynech", on: .question, language: .czech) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "Zopakuj", on: .question, language: .czech) == .repeatQuestion)
        #expect(VoiceCommandMatcher.match(transcript: "opakuj", on: .question, language: .czech) == .repeatQuestion)
        #expect(VoiceCommandMatcher.match(transcript: "Dál", on: .result, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "dále", on: .result, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "Pokračuj", on: .result, language: .czech) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "Znovu", on: .confirmation, language: .czech) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "potvrď", on: .confirmation, language: .czech) == .ok)
        #expect(VoiceCommandMatcher.match(transcript: "ok", on: .confirmation, language: .czech) == .ok)
        #expect(VoiceCommandMatcher.match(transcript: "Stop", on: .confirmation, language: .czech) == .stop)
        #expect(VoiceCommandMatcher.match(transcript: "zruš", on: .confirmation, language: .czech) == .stop)
        #expect(VoiceCommandMatcher.match(transcript: "Pauza", on: .confirmation, language: .czech) == .pause)
    }

    @Test("screen scoping holds for Czech: a valid word on the wrong screen is inert")
    func czechScreenScoping() {
        #expect(VoiceCommandMatcher.match(transcript: "přeskoč", on: .confirmation, language: .czech) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "dál", on: .question, language: .czech) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "pauza", on: .question, language: .czech) == nil)
    }

    @Test("precision: Czech backchannels and particles never fire a command")
    func czechConversationIsInert() {
        // "jo" is THE Czech yes-word; it must never confirm an answer (#175
        // inherits the Slovak precision-over-recall trade).
        for phrase in ["jo", "ano", "dobře", "jasně", "no", "tak", "no tak", "jo jo", "ano ano", "tedy"] {
            for screen: VoiceCommandScreen in [.home, .question, .confirmation, .result] {
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
            for screen: VoiceCommandScreen in [.question, .confirmation, .result] {
                #expect(
                    VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .czech) == nil,
                    "'\(phrase)' must be inert on \(screen)"
                )
            }
        }
    }

    @Test("strict skip tolerates filler padding but not content words (Czech)")
    func czechStrictSkip() {
        #expect(VoiceCommandMatcher.match(transcript: "no přeskoč", on: .question, language: .czech) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "jo, přeskoč", on: .question, language: .czech) == .skip)
        // Content words remain → NOT a skip (it burns a freemium question).
        #expect(VoiceCommandMatcher.match(transcript: "přeskoč tuhle otázku", on: .question, language: .czech) == nil)
    }

    @Test("ambiguity margin: no two Czech commands on one screen collide")
    func czechVariantsAreDisjointPerScreen() {
        for screen: VoiceCommandScreen in [.home, .question, .confirmation, .result] {
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

    @Test("volatile floor holds for Czech: near-miss fires only from a final")
    func czechVolatileFloor() {
        // "znov" vs "znovu" (one edit, 0.8): passes the 0.72 final floor,
        // fails the 0.85 volatile floor.
        #expect(VoiceCommandMatcher.match(transcript: "znov", on: .confirmation, isFinal: true, language: .czech) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "znov", on: .confirmation, isFinal: false, language: .czech) == nil)
    }

    @Test("undo-abort accepts the Czech no-word 'ne' (fail-safe direction only)")
    func czechCancelWords() {
        #expect(VoiceCommandLexicon.isCancelWord("ne", language: .czech))
        #expect(VoiceCommandLexicon.isCancelWord("stop", language: .czech))
        #expect(VoiceCommandLexicon.isCancelWord("zrus", language: .czech))
        // …but "ne" is NOT a `.stop` variant — the destructive direction stays strict.
        #expect(!VoiceCommandLexicon.variants(for: .stop, language: .czech).contains("ne"))
    }

    @Test("driver-facing strings are Czech and quote the button words (#174)")
    func czechDisplayStrings() {
        #expect(VoiceCommandLexicon.hint(on: .home, language: .czech) == "Řekni „start“")
        #expect(VoiceCommandLexicon.hint(on: .question, language: .czech).contains("přeskoč"))
        #expect(VoiceCommandLexicon.hint(on: .confirmation, language: .czech).contains("zruš"))
        #expect(VoiceCommandLexicon.hint(on: .result, language: .czech).contains("dál"))
        #expect(VoiceCommandLexicon.spokenWord(.skip, language: .czech) == "přeskoč")
        #expect(VoiceCommandLexicon.spokenWord(.next, language: .czech) == "dál")
        #expect(VoiceCommandLexicon.listeningCaption(language: .czech) == "POSLOUCHÁM PŘÍKAZY")
        #expect(VoiceCommandLexicon.listeningCaption(language: .czech, short: true) == "POSLOUCHÁM")
        // Slovak: the confirmation hint now names the "Zruš" button, not "stop".
        #expect(VoiceCommandLexicon.hint(on: .confirmation, language: .slovak).contains("zruš"))
        #expect(VoiceCommandLexicon.spokenWord(.stop, language: .slovak) == "zruš")
    }
}
