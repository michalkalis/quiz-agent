//
//  CommandEngineSelection.swift
//  Hangs
//
//  Issue #120 — the launch-time choice of which on-device recognizer feeds the
//  voice-command path, and in which language. Two Apple engines are selectable
//  behind the CommandTranscriberAdapter seam:
//
//    • SpeechTranscriber    — today's engine; English-only for us (its 30
//      supported locales include no Slavic language) but the one with field
//      telemetry and the `.fastResults` latency fix (#119).
//    • DictationTranscriber — supports sk_SK on-device, honors
//      `AnalysisContext.contextualStrings`, and exposes car-shaped content
//      hints (`.farField`, `.shortForm`). No `.fastResults` — its first-
//      hypothesis latency is the open question this switch exists to measure.
//
//  This is a COMPARISON switch, not a migration: the default is today's exact
//  behaviour, so a bad build cannot regress prod, and no engine is removed
//  until a founder car leg says which wins. Launch-time by design — the
//  recognizer, its assets and the audio pipeline are built once at AppState
//  init; `stored` (the Settings picker) takes effect on the next launch.
//

import Foundation

/// The language of the spoken COMMAND grammar (start/skip/… vs štart/preskoč/…).
/// Distinct from `QuizSettings.language` (quiz content) — the founder plays
/// Slovak quizzes with English commands today. Everything above the engine seam
/// that needs locale awareness (lexicon, matcher, hints) keys off this, never
/// off the engine — the engine choice itself stays invisible above the seam.
enum CommandLanguage: String, Sendable, Equatable {
    case english = "en"
    case slovak = "sk"
}

/// One valid (engine, command language) pair. A single 3-case selection rather
/// than two independent axes because the fourth combination — Slovak on
/// SpeechTranscriber — does not exist (no `sk_SK` in its `supportedLocales`,
/// measured against the iOS 26.5 SDK, #119/#120) and must not be constructible.
enum CommandEngineSelection: String, CaseIterable, Sendable, Identifiable {
    /// Default — today's behaviour, exactly (#119 configuration untouched).
    case speechEnglish = "speech-en"
    case dictationEnglish = "dictation-en"
    case dictationSlovak = "dictation-sk"

    var id: String { rawValue }

    // MARK: - Persistence

    nonisolated static let storageKey = "commandEngineSelection"

    /// The persisted choice (the Settings picker reads/writes this). An
    /// unrecognized or missing value falls back to the default engine — a bad
    /// build or a removed case can never strand the founder without commands.
    nonisolated static var stored: CommandEngineSelection {
        get {
            UserDefaults.standard.string(forKey: storageKey)
                .flatMap(CommandEngineSelection.init(rawValue:)) ?? .speechEnglish
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }

    /// The selection ACTIVE for this process — a launch snapshot of `stored`.
    /// Deliberately a `static let`: the engine, its assets, the lexicon default
    /// and the telemetry tags must all agree for the whole session, so a
    /// mid-session Settings change only lands on the next launch (the picker
    /// says so). First access happens at AppState init, before Settings exists.
    static let current: CommandEngineSelection = stored

    // MARK: - Mappings

    /// Recognizer locale for the command path.
    nonisolated var localeIdentifier: String {
        switch self {
        case .speechEnglish, .dictationEnglish: return "en_US"
        case .dictationSlovak: return "sk_SK"
        }
    }

    /// Language of the command grammar — the ONLY thing code above the engine
    /// seam may key off (lexicon variants, hints, fillers).
    nonisolated var commandLanguage: CommandLanguage {
        switch self {
        case .speechEnglish, .dictationEnglish: return .english
        case .dictationSlovak: return .slovak
        }
    }

    /// Stable engine tag carried on every voice hot-path telemetry event so a
    /// Sentry query can slice #119's recall/precision/latency metrics by engine.
    nonisolated var engineTag: String {
        switch self {
        case .speechEnglish: return "speech"
        case .dictationEnglish, .dictationSlovak: return "dictation"
        }
    }

    /// Founder-facing picker label (Settings). Raw display strings — the row is
    /// a diagnostics-grade control like the Status row, not localized copy.
    nonisolated var displayName: String {
        switch self {
        case .speechEnglish: return "Standard · English"
        case .dictationEnglish: return "Dictation · English"
        case .dictationSlovak: return "Dictation · Slovak"
        }
    }
}
