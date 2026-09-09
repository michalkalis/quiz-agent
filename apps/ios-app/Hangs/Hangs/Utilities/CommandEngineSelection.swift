//
//  CommandEngineSelection.swift
//  Hangs
//
//  Issue #120 introduced the choice of which on-device recognizer feeds the
//  voice-command path, and in which language. Two Apple engines sit behind the
//  CommandTranscriberAdapter seam:
//
//    • SpeechTranscriber    — the English engine; its 30 supported locales
//      include no Slavic language, but it has the field telemetry and the
//      `.fastResults` latency fix (#119).
//    • DictationTranscriber — supports sk_SK and cs_CZ on-device, honors
//      `AnalysisContext.contextualStrings`, and exposes car-shaped content
//      hints (`.farField`, `.shortForm`).
//
//  #175 (founder 2026-09-09): the command grammar FOLLOWS THE QUIZ LANGUAGE.
//  There is no Settings picker any more — `forQuizLanguage` is the one
//  mapping, resolved at launch from the persisted quiz settings and again
//  before every listening window (`SilenceDetectionService.setCommandEngine`),
//  so changing the quiz language in Settings takes effect at the next quiz
//  without a restart.
//

import Foundation

/// The language of the spoken COMMAND grammar (start/skip/… vs štart/preskoč/…).
/// Since #175 this is the quiz language (`QuizSettings.language`) — the one
/// thing code above the engine seam (lexicon, matcher, hints) keys off.
enum CommandLanguage: String, Sendable, Equatable {
    case english = "en"
    case slovak = "sk"
    /// #175 — Czech shares the Slovak precision-over-recall design (same
    /// hazards: the mic is open to the language being spoken).
    case czech = "cs"

    /// The command grammar for a quiz language code (ISO 639-1, as stored in
    /// `QuizSettings.language`). Anything that is not Slovak or Czech speaks
    /// English commands — the pre-#120 default.
    static func forQuizLanguage(_ code: String) -> CommandLanguage {
        CommandEngineSelection.forQuizLanguage(code).commandLanguage
    }
}

/// One valid (engine, command language) pair. A single enum rather than two
/// independent axes because the other combinations — Slovak or Czech on
/// SpeechTranscriber — do not exist (no `sk_SK` / `cs_CZ` in its
/// `supportedLocales`, measured against the iOS 26.5 SDK, #119/#120) and must
/// not be constructible.
enum CommandEngineSelection: String, CaseIterable, Sendable {
    /// English — today's engine, exactly (#119 configuration untouched).
    case speechEnglish = "speech-en"
    case dictationEnglish = "dictation-en"
    case dictationSlovak = "dictation-sk"
    /// #175 — cs_CZ is supported by DictationTranscriber on-device (verified
    /// locally 2026-08-31); SpeechTranscriber has no Czech, so — as with
    /// Slovak — the pair is only constructible on the dictation engine.
    case dictationCzech = "dictation-cs"

    /// The engine + grammar for a quiz language code (#175). English stays on
    /// SpeechTranscriber (field-proven, `.fastResults`); `dictationEnglish`
    /// remains only as a measurement configuration for tests.
    nonisolated static func forQuizLanguage(_ code: String) -> CommandEngineSelection {
        switch code.lowercased().prefix(2) {
        case "sk": return .dictationSlovak
        case "cs": return .dictationCzech
        default: return .speechEnglish
        }
    }

    // MARK: - Mappings

    /// Recognizer locale for the command path.
    nonisolated var localeIdentifier: String {
        switch self {
        case .speechEnglish, .dictationEnglish: return "en_US"
        case .dictationSlovak: return "sk_SK"
        case .dictationCzech: return "cs_CZ"
        }
    }

    /// Language of the command grammar — the ONLY thing code above the engine
    /// seam may key off (lexicon variants, hints, fillers).
    nonisolated var commandLanguage: CommandLanguage {
        switch self {
        case .speechEnglish, .dictationEnglish: return .english
        case .dictationSlovak: return .slovak
        case .dictationCzech: return .czech
        }
    }

    /// Stable engine tag carried on every voice hot-path telemetry event so a
    /// Sentry query can slice #119's recall/precision/latency metrics by engine.
    nonisolated var engineTag: String {
        switch self {
        case .speechEnglish: return "speech"
        case .dictationEnglish, .dictationSlovak, .dictationCzech: return "dictation"
        }
    }
}
