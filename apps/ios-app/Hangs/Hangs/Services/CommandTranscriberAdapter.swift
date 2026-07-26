//
//  CommandTranscriberAdapter.swift
//  Hangs
//
//  Issue #120 — the engine seam. The two Apple on-device transcribers
//  (`SpeechTranscriber`, `DictationTranscriber`) become interchangeable behind
//  this adapter so their recognition quality can be compared on the same audio
//  with the same telemetry. The seam sits INSIDE SilenceDetectionService — the
//  service still owns the SpeechDetector, the SpeechAnalyzer, the AVAudioEngine
//  and the tap; an adapter owns exactly three things:
//
//    1. constructing + configuring its CONCRETE transcriber (the per-engine
//       Preset/ReportingOption/ContentHint sets do not line up, so there is no
//       shared config type — two concrete adapters instead of a genericization
//       over Apple's associatedtypes),
//    2. normalizing its concrete `Result` stream into `CommandTranscript`
//       (Apple's `SpeechModule.results` cannot be consumed through a bare
//       existential — associatedtype `Results`),
//    3. declaring its CAPABILITIES explicitly (contextual-string biasing exists
//       on one engine and not the other; the service feeds the lexicon to the
//       engine that accepts it and skips the one that ignores it — never a
//       lowest-common-denominator config).
//
//  Nothing above SilenceDetectionServiceProtocol knows which adapter runs.
//

import Foundation
import Speech

// MARK: - Session

/// One listening window's worth of engine: the concrete module (handed to
/// `SpeechAnalyzer(modules:)` / format negotiation as an existential) plus its
/// results already normalized to the app's `CommandTranscript`.
struct CommandTranscriberSession {
    let module: any SpeechModule
    let transcripts: AsyncThrowingStream<CommandTranscript, Error>
}

// MARK: - Adapter protocol

@MainActor
protocol CommandTranscriberAdapter: AnyObject {
    /// Stable engine tag for telemetry ("speech" / "dictation") — the slice key
    /// for every Sentry comparison query (#120).
    nonisolated var engineTag: String { get }

    /// The recognizer locale this adapter was built for.
    nonisolated var locale: Locale { get }

    /// Vocabulary to bias the recognizer with via
    /// `AnalysisContext.contextualStrings`, or `nil` when the engine IGNORES
    /// contextual strings (SpeechTranscriber — Apple DTS, forum 801877). The
    /// capability asymmetry is modelled as presence/absence, deliberately not as
    /// an empty list: `nil` means "don't bother calling setContext at all".
    var contextualStrings: [String]? { get }

    /// Locale membership checks — `supportedLocales.contains` is the ONLY valid
    /// gate. `supportedLocale(equivalentTo:)` normalizes an identifier rather
    /// than testing membership and returns sk_SK even for the engine that does
    /// not support it (#120 measured trap) — never use it for gating.
    func supportedLocales() async -> [Locale]
    func installedLocales() async -> [Locale]

    /// Download/install the on-device model assets for `locale`. Declares asset
    /// needs with a module built by the SAME factory `makeSession()` uses — a
    /// config drift between the two would leave `prepareAssets()` reporting
    /// `.ready` while `analyzer.start` throws (#119 drift warning).
    func installAssets() async throws

    /// A fresh transcriber module + normalized transcript stream for one
    /// listening window (the analyzer lifecycle is per-window).
    func makeSession() -> CommandTranscriberSession
}

// MARK: - Result-stream bridging

/// Consume a concrete module's `results` (associatedtype-bound, so this must be
/// generic) and re-emit them as normalized `CommandTranscript`s. `text` extracts
/// the attributed transcript from the concrete `Result`; `isFinal` comes from
/// `SpeechModuleResult`. Cancellation of the consumer terminates the stream,
/// which cancels the bridging task via `onTermination`.
private nonisolated func bridgeResults<M: SpeechModule>(
    of module: M,
    text: @escaping @Sendable (M.Result) -> AttributedString
) -> AsyncThrowingStream<CommandTranscript, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await result in module.results {
                    continuation.yield(
                        CommandTranscript(text: String(text(result).characters), isFinal: result.isFinal)
                    )
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - SpeechTranscriber (today's engine)

/// Today's engine, configuration IDENTICAL to pre-#120 behaviour. English-only
/// for us: its 30 supported locales include no Slavic language (measured,
/// iOS 26.5 SDK). Ignores contextual strings; word choice + the fuzzy matcher
/// remain the vocabulary defence on this engine.
@MainActor
final class SpeechTranscriberCommandAdapter: CommandTranscriberAdapter {
    nonisolated let engineTag = "speech"
    nonisolated let locale: Locale
    /// Capability absent — this engine ignores `AnalysisContext.contextualStrings`.
    var contextualStrings: [String]? { nil }

    nonisolated init(locale: Locale = Locale(identifier: "en_US")) {
        self.locale = locale
    }

    /// The ONE place this engine is configured (shared by asset install and the
    /// live session — see the protocol's drift warning).
    ///
    /// `.volatileResults` + `.fastResults` are #119's load-bearing latency fix —
    /// measured on this exact configuration: without `.fastResults` the
    /// transcriber emits NOTHING until ~4 s of audio (volatile-first 4211 ms), so
    /// any command window closing earlier yields zero transcripts (37 of 56 in
    /// the field data); with it the first hypothesis lands at 1155 ms. Removing
    /// either flag re-breaks #119. Still NOT `.alternativeTranscriptions` — the
    /// primary transcript is letter-perfect for real command words and N-best
    /// would only widen the false-fire surface.
    private nonisolated func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
    func installedLocales() async -> [Locale] { await SpeechTranscriber.installedLocales }

    func installAssets() async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()]) {
            try await request.downloadAndInstall()
        }
    }

    func makeSession() -> CommandTranscriberSession {
        let transcriber = makeTranscriber()
        return CommandTranscriberSession(
            module: transcriber,
            transcripts: bridgeResults(of: transcriber) { $0.text }
        )
    }
}

// MARK: - DictationTranscriber (the challenger)

/// The comparison engine (#120). Three structural advantages over
/// SpeechTranscriber for a seven-word command grammar: it honors
/// `contextualStrings` (vocabulary biasing beats spelling variants + edit
/// distance), it exposes car-shaped content hints (`.farField` — a cabin mic;
/// `.shortForm` — phrase-length input), and it supports sk_SK on-device. Its
/// open risk: no `.fastResults`, so first-hypothesis latency — the metric #119
/// showed is decisive — is unproven; `.frequentFinalization` is the nearest
/// analogue and its semantics are finalization cadence, not first-hypothesis
/// latency. The telemetry this seam adds exists to measure exactly that.
@MainActor
final class DictationTranscriberCommandAdapter: CommandTranscriberAdapter {
    nonisolated let engineTag = "dictation"
    nonisolated let locale: Locale
    private nonisolated let language: CommandLanguage

    /// Capability present — feed the recognizer the exact command vocabulary
    /// (real diacritics, display forms) for the active command language.
    var contextualStrings: [String]? {
        VoiceCommandLexicon.contextualVocabulary(for: language)
    }

    nonisolated init(locale: Locale, language: CommandLanguage) {
        self.locale = locale
        self.language = language
    }

    /// Explicit configuration rather than the `.phrase` preset: a preset's
    /// composition is a convenience bundle, and the two options that are
    /// load-bearing for us must be deliberate — `.volatileResults` (the consumer
    /// contract: hypotheses before the end-of-speech endpoint) and
    /// `.frequentFinalization` (the closest lever this engine has toward #119's
    /// `.fastResults`). Content hints name our exact acoustics: `.shortForm`
    /// (phrase-length commands) + `.farField` (a car-cabin mic).
    private nonisolated func makeTranscriber() -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [.shortForm, .farField],
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: []
        )
    }

    func supportedLocales() async -> [Locale] { await DictationTranscriber.supportedLocales }
    func installedLocales() async -> [Locale] { await DictationTranscriber.installedLocales }

    func installAssets() async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber()]) {
            try await request.downloadAndInstall()
        }
    }

    func makeSession() -> CommandTranscriberSession {
        let transcriber = makeTranscriber()
        return CommandTranscriberSession(
            module: transcriber,
            transcripts: bridgeResults(of: transcriber) { $0.text }
        )
    }
}

// MARK: - Selection → adapter

extension CommandEngineSelection {
    /// The adapter for this launch-time selection. Called once, at AppState init.
    @MainActor
    func makeAdapter() -> CommandTranscriberAdapter {
        switch self {
        case .speechEnglish:
            return SpeechTranscriberCommandAdapter(locale: Locale(identifier: localeIdentifier))
        case .dictationEnglish, .dictationSlovak:
            return DictationTranscriberCommandAdapter(
                locale: Locale(identifier: localeIdentifier),
                language: commandLanguage
            )
        }
    }
}
