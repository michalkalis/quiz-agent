//
//  TranscriberEngineTests.swift
//  HangsTests
//
//  Issue #120 — the engine seam and the Slovak command grammar. Three suites:
//
//   • CommandEngineSelectionTests — the launch-time (engine, language) pairs:
//     only the three VALID combinations exist (Slovak on SpeechTranscriber is
//     unconstructible), persistence falls back to today's engine on garbage.
//   • CommandTranscriberAdapterTests — CONFIG-level adapter checks (the
//     Simulator cannot run a real recognizer, so no fake-recognition tests):
//     the capability asymmetry is declared, not averaged — contextual strings
//     absent on SpeechTranscriber, present with the right vocabulary on
//     DictationTranscriber — and each adapter builds its own concrete module.
//   • SlovakCommandGrammarTests — the Slovak lexicon under the matcher, ranked
//     precision over recall: in Slovak mode the mic is open to the language
//     being SPOKEN in the car, so ordinary conversation (backchannels "áno",
//     "dobre", "hej"; particles "no", "tak") must never fire a command, while
//     the multi-syllable imperatives (preskoč, zopakuj, ďalej…) must.
//
//  Plus the first-hypothesis latency anchor (#120's decisive comparison
//  metric), driven with a fake clock — no sleeps.
//

import Foundation
@testable import Hangs
import Speech
import Testing

// MARK: - Engine selection

@Suite("CommandEngineSelection (#120)")
@MainActor
struct CommandEngineSelectionTests {
    @Test("only three valid engine-language pairs exist; Slovak is dictation-only")
    func validPairs() {
        #expect(CommandEngineSelection.allCases.count == 3)
        // No case maps SpeechTranscriber to Slovak — that combination does not
        // exist in the SDK (no sk_SK in SpeechTranscriber.supportedLocales) and
        // must be unconstructible, not merely discouraged.
        for selection in CommandEngineSelection.allCases where selection.engineTag == "speech" {
            #expect(selection.commandLanguage == .english)
        }
    }

    @Test("mappings: locale, language and telemetry tag agree per case")
    func mappings() {
        #expect(CommandEngineSelection.speechEnglish.localeIdentifier == "en_US")
        #expect(CommandEngineSelection.speechEnglish.commandLanguage == .english)
        #expect(CommandEngineSelection.speechEnglish.engineTag == "speech")

        #expect(CommandEngineSelection.dictationEnglish.localeIdentifier == "en_US")
        #expect(CommandEngineSelection.dictationEnglish.commandLanguage == .english)
        #expect(CommandEngineSelection.dictationEnglish.engineTag == "dictation")

        #expect(CommandEngineSelection.dictationSlovak.localeIdentifier == "sk_SK")
        #expect(CommandEngineSelection.dictationSlovak.commandLanguage == .slovak)
        #expect(CommandEngineSelection.dictationSlovak.engineTag == "dictation")
    }

    @Test("stored: round-trips, and garbage/missing falls back to today's engine")
    func storedFallsBackSafely() {
        let original = UserDefaults.standard.string(forKey: CommandEngineSelection.storageKey)
        defer { UserDefaults.standard.set(original, forKey: CommandEngineSelection.storageKey) }

        CommandEngineSelection.stored = .dictationSlovak
        #expect(CommandEngineSelection.stored == .dictationSlovak)

        // A removed case / corrupted value must degrade to the DEFAULT engine —
        // a bad build can never strand the founder without commands (#120).
        UserDefaults.standard.set("no-such-engine", forKey: CommandEngineSelection.storageKey)
        #expect(CommandEngineSelection.stored == .speechEnglish)

        UserDefaults.standard.removeObject(forKey: CommandEngineSelection.storageKey)
        #expect(CommandEngineSelection.stored == .speechEnglish)
    }
}

// MARK: - Adapters (config level)

@Suite("CommandTranscriberAdapter (#120)")
@MainActor
struct CommandTranscriberAdapterTests {
    @Test("capability asymmetry is explicit: SpeechTranscriber declares NO contextual strings")
    func speechAdapterDeclaresNoContextualStrings() {
        let adapter = SpeechTranscriberCommandAdapter()
        // nil (capability absent), NOT an empty list — the service must skip
        // setContext entirely for the engine that ignores it, never feed a
        // lowest-common-denominator config (#120 constraint).
        #expect(adapter.contextualStrings == nil)
        #expect(adapter.engineTag == "speech")
        #expect(adapter.locale.identifier == "en_US")
    }

    @Test("dictation adapter biases with the command vocabulary of its language")
    func dictationAdapterDeclaresVocabulary() {
        let english = DictationTranscriberCommandAdapter(
            locale: Locale(identifier: "en_US"), language: .english
        )
        #expect(english.engineTag == "dictation")
        #expect(english.contextualStrings?.contains("start") == true)
        #expect(english.contextualStrings?.contains("skip") == true)

        let slovak = DictationTranscriberCommandAdapter(
            locale: Locale(identifier: "sk_SK"), language: .slovak
        )
        #expect(slovak.locale.identifier == "sk_SK")
        // Real diacritics — the recognizer is biased toward the SPOKEN forms;
        // folding is the matcher's job, not the engine's.
        #expect(slovak.contextualStrings?.contains("preskoč") == true)
        #expect(slovak.contextualStrings?.contains("štart") == true)
        #expect(slovak.contextualStrings?.contains("ďalej") == true)
    }

    @Test("each adapter builds its own concrete module (two adapters, no genericization)")
    func adaptersBuildConcreteModules() {
        let speechSession = SpeechTranscriberCommandAdapter().makeSession()
        #expect(speechSession.module is SpeechTranscriber)

        let dictationSession = DictationTranscriberCommandAdapter(
            locale: Locale(identifier: "sk_SK"), language: .slovak
        ).makeSession()
        #expect(dictationSession.module is DictationTranscriber)
    }

    @Test("selection → adapter factory hands out the matching engine + locale")
    func selectionFactory() {
        #expect(CommandEngineSelection.speechEnglish.makeAdapter() is SpeechTranscriberCommandAdapter)
        let slovak = CommandEngineSelection.dictationSlovak.makeAdapter()
        #expect(slovak is DictationTranscriberCommandAdapter)
        #expect(slovak.locale.identifier == "sk_SK")
        #expect(slovak.engineTag == "dictation")
    }

    @Test("simulator reality probe (#120): does DictationTranscriber run here at all?")
    func simulatorLocaleProbe() async {
        // NON-GATING by design: SpeechTranscriber reports zero locales on the
        // Simulator, which is why the whole suite mocks at the protocol level.
        // This probe records whether DictationTranscriber is any better — a
        // genuine testability win if it is — without failing on either answer.
        let supported = await DictationTranscriber.supportedLocales
        let installed = await DictationTranscriber.installedLocales
        print("#120 probe: DictationTranscriber supportedLocales=\(supported.count) installedLocales=\(installed.count) sk_SK-supported=\(supported.contains { $0.identifier(.bcp47) == "sk-SK" })")
    }
}

// MARK: - Slovak command grammar

@Suite("Slovak command grammar (#120)")
struct SlovakCommandGrammarTests {
    @Test("every Slovak variant is stored pre-normalized (folded, lowercase)")
    func variantsAreNormalized() {
        for command in VoiceCommand.allCases {
            for variant in VoiceCommandLexicon.variants(for: command, language: .slovak) {
                #expect(
                    VoiceCommandMatcher.normalize(variant) == variant,
                    "variant '\(variant)' must survive normalize unchanged"
                )
            }
        }
    }

    @Test("recall: each Slovak command word routes on its screen, diacritics included")
    func slovakCommandsRoute() {
        // Raw transcripts as a Slovak recognizer would render them — normalize
        // folds the diacritics before matching.
        #expect(VoiceCommandMatcher.match(transcript: "Štart", on: .home, language: .slovak) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "Preskoč", on: .question, language: .slovak) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "vynechaj", on: .question, language: .slovak) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "Zopakuj", on: .question, language: .slovak) == .repeatQuestion)
        #expect(VoiceCommandMatcher.match(transcript: "Ďalej", on: .result, language: .slovak) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "pokračuj", on: .result, language: .slovak) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "Znova", on: .confirmation, language: .slovak) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "potvrď", on: .confirmation, language: .slovak) == .ok)
        #expect(VoiceCommandMatcher.match(transcript: "Stop", on: .confirmation, language: .slovak) == .stop)
        #expect(VoiceCommandMatcher.match(transcript: "zruš", on: .confirmation, language: .slovak) == .stop)
    }

    @Test("precision: Slovak backchannels and particles never fire a command")
    func slovakConversationIsInert() {
        // The words a passenger conversation is MADE of — deliberately filler,
        // so a backchannel-only utterance strips to zero content tokens. "áno"
        // must NOT confirm an answer; that is the precision-over-recall trade
        // the Slovak set is built on (#120).
        for phrase in ["áno", "dobre", "hej", "jasné", "no", "tak", "no tak", "áno áno", "dobre dobre"] {
            for screen: VoiceCommandScreen in [.home, .question, .confirmation, .result] {
                #expect(
                    VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .slovak) == nil,
                    "'\(phrase)' must be inert on \(screen)"
                )
            }
        }
    }

    @Test("precision: ordinary Slovak sentences are rejected by the content-token cap")
    func slovakSentencesAreInert() {
        for phrase in ["to bolo dobré", "poď ďalej ideme", "no tak to preskočíme neskôr"] {
            for screen: VoiceCommandScreen in [.question, .confirmation, .result] {
                #expect(
                    VoiceCommandMatcher.match(transcript: phrase, on: screen, language: .slovak) == nil,
                    "'\(phrase)' must be inert on \(screen)"
                )
            }
        }
    }

    @Test("strict skip tolerates filler padding but not content words (Slovak)")
    func slovakStrictSkip() {
        // "no preskoč" — particle + imperative: filler strips, skip fires.
        #expect(VoiceCommandMatcher.match(transcript: "no preskoč", on: .question, language: .slovak) == .skip)
        // "preskoč túto otázku" — content words remain → NOT a skip (it burns
        // a freemium question; the utterance must BE the skip word).
        #expect(VoiceCommandMatcher.match(transcript: "preskoč túto otázku", on: .question, language: .slovak) == nil)
    }

    @Test("volatile floor holds for Slovak: near-miss fires only from a final")
    func slovakVolatileFloor() {
        // One edit on "preskoc" ("preskok" — a real Slovak noun, 'a jump').
        // Skip is final-only anyway, so probe the floor on a benign command:
        // "dalej" vs "dale" (one edit, 0.8): passes the 0.72 final floor,
        // fails the 0.85 volatile floor.
        #expect(VoiceCommandMatcher.match(transcript: "dale", on: .result, isFinal: true, language: .slovak) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "dale", on: .result, isFinal: false, language: .slovak) == nil)
    }

    @Test("undo-abort accepts the Slovak no-word 'nie' (fail-safe direction only)")
    func slovakCancelWords() {
        #expect(VoiceCommandLexicon.isCancelWord("nie", language: .slovak))
        #expect(VoiceCommandLexicon.isCancelWord("stop", language: .slovak))
        #expect(VoiceCommandLexicon.isCancelWord("zrus", language: .slovak))
        // …but "nie" is NOT a `.stop` variant — the destructive direction stays
        // strict (a false `.stop` discards an in-flight answer).
        #expect(!VoiceCommandLexicon.variants(for: .stop, language: .slovak).contains("nie"))
    }

    @Test("driver-facing strings are language-scoped: hints and spoken words")
    func slovakDisplayStrings() {
        #expect(VoiceCommandLexicon.hint(on: .home, language: .slovak).contains("štart"))
        #expect(VoiceCommandLexicon.hint(on: .question, language: .slovak).contains("preskoč"))
        #expect(VoiceCommandLexicon.spokenWord(.skip, language: .slovak) == "preskoč")
        #expect(VoiceCommandLexicon.spokenWord(.next, language: .slovak) == "ďalej")
        // English is untouched (the default path — pinned explicitly here, and
        // implicitly by every pre-#120 test that omits the language argument).
        #expect(VoiceCommandLexicon.hint(on: .home, language: .english) == #"Say "start""#)
        #expect(VoiceCommandLexicon.spokenWord(.skip, language: .english) == "skip")
    }
}

// MARK: - First-hypothesis latency (#120's decisive metric)

@Suite("First-hypothesis latency anchor (#120)")
@MainActor
struct FirstHypothesisLatencyTests {
    @Test("VAD speech-start arms the anchor; the first transcript consumes it once")
    func anchorArmsAndConsumesOnce() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let service = SilenceDetectionService(now: { currentTime })

        service.handleSpeechDetectorResult(speechDetected: true) // idle → speechActive
        currentTime = currentTime.addingTimeInterval(1.2)

        // First transcript of the utterance: 1200 ms from VAD speech-start.
        #expect(service.consumeFirstHypothesisLatencyMs() == 1200)
        // One-shot: the second transcript of the same utterance reports nothing.
        #expect(service.consumeFirstHypothesisLatencyMs() == nil)
    }

    @Test("a resumed utterance does not re-arm; a NEW utterance does")
    func anchorFollowsUtteranceBoundaries() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        var currentTime = Date(timeIntervalSince1970: 2_000)
        let service = SilenceDetectionService(now: { currentTime })

        service.handleSpeechDetectorResult(speechDetected: true)
        _ = service.consumeFirstHypothesisLatencyMs() // consumed by a transcript

        // Brief pause + resume = the SAME utterance — must not re-arm (the
        // metric means "how long until the engine said anything", once).
        service.handleSpeechDetectorResult(speechDetected: false)
        service.handleSpeechDetectorResult(speechDetected: true)
        #expect(service.consumeFirstHypothesisLatencyMs() == nil)

        // Silence past the stop threshold ends the utterance (state → idle)…
        service.handleSpeechDetectorResult(speechDetected: false)
        currentTime = currentTime.addingTimeInterval(5)
        service.handleSpeechDetectorResult(speechDetected: false)

        // …so the next speech-start is a NEW utterance and re-arms the anchor.
        service.handleSpeechDetectorResult(speechDetected: true)
        currentTime = currentTime.addingTimeInterval(0.8)
        #expect(service.consumeFirstHypothesisLatencyMs() == 800)
    }
}
