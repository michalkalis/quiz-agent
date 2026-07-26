//
//  SilenceDetectionService.swift
//  Hangs
//
//  Continuous on-device voice activity detection via iOS 26 SpeechDetector,
//  plus the paired command transcriber that feeds voice commands (#77). Since
//  #120 the transcriber is engine-swappable behind CommandTranscriberAdapter
//  (SpeechTranscriber en-US by default; DictationTranscriber en-US/sk-SK as the
//  launch-time comparison engine) — nothing above this service knows which one
//  runs. Emits four per-acquisition streams (see StreamChannel):
//    • silence events        — speechStarted / silenceAfterSpeech (auto-stop).
//    • barge-in events       — speech detected during TTS on an external route.
//    • command transcripts   — text (volatile + final) for VoiceCommandMatcher.
//    • command availability  — fail-loud recognizer readiness updates.
//
//  The AVAudioEngine/SpeechAnalyzer lifecycle lives in the sibling
//  SilenceDetectionService+Engine.swift; this file keeps the state machine,
//  authorization (#105) and asset preparation.
//

// @preconcurrency: AVAudio tap/converter closures are not @Sendable. Without this,
// Swift 6 infers @MainActor isolation for a closure passed from a @MainActor class
// and the runtime isolation check crashes when AVAudio invokes the tap on its
// audio thread (see Sentry CARQUIZ-1). The tap itself now lives in
// SilenceDetectionService+Engine.swift, which carries the same annotation.
@preconcurrency import AVFoundation
import Foundation
import os

// @preconcurrency: same crash class as AVFoundation above — the legacy
// SFSpeechRecognizer.requestAuthorization completion fires on a TCC background
// queue; without this the inferred @MainActor isolation check traps at launch.
@preconcurrency import Speech

// MARK: - Events

/// Events emitted by silence detection (SpeechDetector VAD)
enum SilenceEvent: Sendable, Equatable {
    case speechStarted
    case silenceAfterSpeech(duration: TimeInterval)
}

/// Fail-loud availability of the on-device English voice-command transcriber
/// (#77 device fix). Every failure that used to be swallowed (missing model
/// assets, `analyzer.start` throw, nil audio format, transcriber stream error)
/// now lands here so the UI/diagnostics can see WHY the app degraded to buttons.
enum VoiceCommandAvailability: Sendable, Equatable {
    /// Not yet determined (prepareAssets hasn't finished).
    case unknown
    /// en-US model assets are being downloaded/installed.
    case installingAssets
    /// Recognizer assets installed — commands can work.
    case ready
    /// Commands cannot work; the app is button-only. Reason is human-readable.
    case unavailable(reason: String)
}

/// One transcriber result on the command path, carrying its own finality.
///
/// WHY finality travels WITH the text (build-33 field fix, 2026-07-24): the
/// command stream used to be finals-only, but a SpeechTranscriber only finalizes
/// a segment after an end-of-speech endpoint, and each repetition EXTENDS the
/// segment and pushes that endpoint further out. Sentry caught the pathology
/// verbatim — a single final containing "start" seven times, delivered after the
/// listening window had already closed. Volatile hypotheses are now forwarded
/// too so a one-word command can fire while the founder is still speaking; the
/// consumer needs `isFinal` to enforce at-most-one-command-per-utterance so the
/// repeated hypotheses of one utterance cannot double-fire.
struct CommandTranscript: Sendable, Equatable {
    let text: String
    let isFinal: Bool
}

// MARK: - Protocol

@MainActor
protocol SilenceDetectionServiceProtocol: AnyObject, Sendable {
    // Streams are acquired per consumer via make*Stream() — each call mints a
    // FRESH AsyncStream (see StreamChannel). Never store one stream for the
    // service's lifetime: consumers are re-armed (and their tasks cancelled) on
    // every listening window, and cancelling a `for await` permanently finishes
    // a shared AsyncStream — the dead-voice-commands P0.
    func makeSilenceEventStream() -> AsyncStream<SilenceEvent>
    func makeBargeInStream() -> AsyncStream<Void>

    /// English transcripts from the paired command transcriber (#77, task 77.5),
    /// BOTH volatile hypotheses and finals, each tagged via `CommandTranscript`.
    /// The SpeechDetector VAD requires a paired SpeechTranscriber (CARQUIZ-3);
    /// rather than leave that transcriber idle we re-locale it to English (P2 —
    /// commands are English-only for all users) and surface its results here for
    /// the screen-scoped `VoiceCommandMatcher`. The answer path stays Slovak
    /// ElevenLabs — this stream is command-only and is consumed only inside a
    /// listening window (never during recording).
    func makeCommandTranscriptStream() -> AsyncStream<CommandTranscript>

    /// Current availability of the voice-command recognizer (fail-loud, #77).
    /// `.unavailable` means the app has degraded to the manual button flow.
    var commandAvailability: VoiceCommandAvailability { get }

    /// Availability changes, pushed on EVERY `commandAvailability` mutation.
    /// `commandAvailability` is a plain (non-observable) property, but the en-US
    /// model can finish installing asynchronously long after launch and flip it to
    /// `.ready`; with no signal the "LISTENING FOR COMMANDS" indicator never
    /// appears on the idle Home screen even though commands now work (the "voice
    /// commands don't work" discoverability symptom). The view-model mirrors this
    /// stream into an observable `@Published` so SwiftUI re-renders on every change.
    func makeCommandAvailabilityStream() -> AsyncStream<VoiceCommandAvailability>

    func startListening() async
    func stopListening()

    /// Signal whether TTS is currently playing (enables barge-in detection).
    func setTTSPlaybackActive(_ active: Bool)
}

// MARK: - Implementation

@MainActor
final class SilenceDetectionService: SilenceDetectionServiceProtocol {
    // Per-acquisition stream channels (dead-voice-commands fix): each consumer
    // re-arm gets a fresh AsyncStream, so cancelling a replaced consumer can
    // never starve the current one. See StreamChannel.swift for the invariant.
    private let silenceChannel = StreamChannel<SilenceEvent>()
    private let bargeInChannel = StreamChannel<Void>()
    let commandChannel = StreamChannel<CommandTranscript>()
    private let commandAvailabilityChannel = StreamChannel<VoiceCommandAvailability>()

    func makeSilenceEventStream() -> AsyncStream<SilenceEvent> { silenceChannel.makeStream() }
    func makeBargeInStream() -> AsyncStream<Void> { bargeInChannel.makeStream() }
    func makeCommandTranscriptStream() -> AsyncStream<CommandTranscript> { commandChannel.makeStream() }
    func makeCommandAvailabilityStream() -> AsyncStream<VoiceCommandAvailability> { commandAvailabilityChannel.makeStream() }

    // Engine/analyzer state. Internal rather than `private` (like `commandChannel`
    // above) because the engine lifecycle lives in the sibling
    // SilenceDetectionService+Engine.swift: `private` is file-scoped and would not
    // reach an extension in another file.
    var audioEngine: AVAudioEngine?
    var analyzer: SpeechAnalyzer?
    var analyzerTask: Task<Void, Never>?
    var detectionTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// The engine seam (#120): constructs, configures and normalizes the
    /// concrete transcriber. Chosen once at launch (CommandEngineSelection);
    /// everything below reads capabilities off it instead of naming an engine.
    let transcriberEngine: CommandTranscriberAdapter

    /// Segment-scoped sampling flag for the "voice transcriber result" log —
    /// first volatile of each segment plus every final (see
    /// `handleEngineTranscript`). Reset per listening window.
    var loggedVolatileThisSegment = false

    /// When the VAD last opened an utterance (idle → speechActive) with no
    /// transcriber result seen yet — the anchor for the FIRST-HYPOTHESIS LATENCY
    /// metric (#120). This is the number the engine comparison turns on: #119
    /// showed a recognizer that answers after the command window closes is
    /// useless no matter how accurate. Consumed (once) by the first transcript
    /// of the utterance; cleared on teardown so a stale anchor can never span
    /// windows.
    var pendingFirstHypothesisSince: Date?

    /// Latched when an engine that had voice processing armed refused to start.
    /// Enabling VPIO on the input node also enables it on this engine's
    /// unconnected output node; if that combination is rejected on some route we
    /// must degrade to an unprocessed mic rather than lose voice commands
    /// entirely, so the next listening window skips voice processing.
    var voiceProcessingUnsupported = false

    private var isTTSPlaybackActive = false

    /// Fail-loud command availability (#77). Written by `prepareAssets()` and by
    /// every failure path that previously swallowed its error silently. Each
    /// mutation is pushed to `commandAvailabilityUpdates` so an observer (the
    /// view-model's `@Published` mirror) re-renders reactively (#96 S2). `didSet`
    /// does not fire for the initializer's value — observers see changes only.
    /// Setter is internal (not `private(set)`) because the writers live in the
    /// sibling-file extensions (+Assets, +Engine) and `private` is file-scoped.
    var commandAvailability: VoiceCommandAvailability = .unknown {
        didSet { commandAvailabilityChannel.yield(commandAvailability) }
    }

    /// Whether the DEVICE-level pre-conditions hold: permission granted and the
    /// selected engine's model assets installed. Set once by `prepareAssets()`.
    /// Separate from `commandAvailability`, which conflated a durable device
    /// capability with a per-window one — see `recoverAvailabilityForLiveWindow`.
    var assetsPrepared = false

    enum State {
        case idle
        /// Speech is active; `since` marks when the utterance began so the
        /// min-speech-duration blip guard (77.11) can measure it.
        case speechActive(since: Date)
        /// Silence is accumulating after an utterance. `speechStart` is carried
        /// so the blip guard knows how long the preceding speech lasted.
        case silenceAccumulating(speechStart: Date, since: Date)
    }

    var state: State = .idle

    private let now: @MainActor () -> Date

    /// Requests speech-recognition authorization and returns the resulting
    /// status. Defaults to the real `SFSpeechRecognizer` dialog; tests inject
    /// a stub so the decision logic can run without the system prompt (#105).
    /// Internal, not `private` — consumed by the +Assets sibling-file extension.
    let authorizationProvider: () async -> SFSpeechRecognizerAuthorizationStatus

    init(
        now: @escaping @MainActor () -> Date = { Date() },
        authorizationProvider: (() async -> SFSpeechRecognizerAuthorizationStatus)? = nil,
        engine: CommandTranscriberAdapter? = nil
    ) {
        self.now = now
        self.authorizationProvider = authorizationProvider ?? Self.requestSystemAuthorization
        let resolvedEngine = engine ?? CommandEngineSelection.current.makeAdapter()
        transcriberEngine = resolvedEngine
        // Stamp the process-wide engine/locale telemetry tags (#120): every
        // `.voice`-category SentryLog event — including the ones emitted ABOVE
        // this service, which must not know the engine — carries them, so a
        // Sentry query can slice recall/precision/latency by engine.
        VoiceTelemetryContext.set(
            engine: resolvedEngine.engineTag, locale: resolvedEngine.locale.identifier
        )
    }

    deinit {
        silenceChannel.finish()
        bargeInChannel.finish()
        commandChannel.finish()
        commandAvailabilityChannel.finish()
    }

    // MARK: - Authorization + assets
    //
    // requestAuthorizationAndPrepareAssets() / prepareAssets() /
    // markCommandsUnavailable() — the #105 permission flow and the #77/#120
    // engine-asset preparation — live in SilenceDetectionService+Assets.swift.

    // MARK: - Lifecycle
    //
    // startListening() / stopListening() — the AVAudioEngine + SpeechAnalyzer
    // lifecycle — live in SilenceDetectionService+Engine.swift.

    func setTTSPlaybackActive(_ active: Bool) {
        isTTSPlaybackActive = active
    }

    // MARK: - Result Handling

    func handleSpeechDetectorResult(speechDetected: Bool) {
        if speechDetected {
            // Barge-in: only when TTS is playing on an external audio route
            // (echo from the device speaker would trigger false positives).
            if isTTSPlaybackActive && isExternalAudioRoute() {
                bargeInChannel.yield(())
                Logger.voice.info("🗣️ Barge-in: speech detected during TTS on external route")
                return
            }

            switch state {
            case .idle:
                state = .speechActive(since: now())
                // Anchor the first-hypothesis latency clock (#120): measured
                // from VAD speech-start (engine-independent — SpeechDetector
                // runs identically under both engines) to the first transcriber
                // result, so the number is comparable across engines.
                pendingFirstHypothesisSince = now()
                silenceChannel.yield(.speechStarted)
                Logger.voice.debug("🔇 Silence detection: speech started")
                // VAD-transition telemetry: if these never fire on a device with a
                // silent command path, audio isn't reaching the analyzer at all.
                SentryLog.info("vad speech began", category: .voice)
            case let .silenceAccumulating(speechStart, _):
                // Resume the SAME utterance — keep its original start so a brief
                // mid-utterance pause doesn't reset the speech-duration clock.
                state = .speechActive(since: speechStart)
                Logger.voice.debug("🔇 Silence detection: speech resumed")
            case .speechActive:
                break
            }
        } else {
            switch state {
            case let .speechActive(speechStart):
                state = .silenceAccumulating(speechStart: speechStart, since: now())
                Logger.voice.debug("🔇 Silence detection: silence started after speech")
            case let .silenceAccumulating(speechStart, since):
                let silenceElapsed = now().timeIntervalSince(since)
                let speechDuration = since.timeIntervalSince(speechStart)
                switch SilenceStopDecision.evaluate(speechDuration: speechDuration, silenceElapsed: silenceElapsed) {
                case .wait:
                    break
                case .stop:
                    silenceChannel.yield(.silenceAfterSpeech(duration: silenceElapsed))
                    state = .idle
                    SentryLog.info("vad speech ended", category: .voice, attributes: ["speechSecs": speechDuration])
                    Logger.voice.debug("🔇 Silence detection: threshold reached (\(String(format: "%.1f", silenceElapsed), privacy: .public)s)")
                case .rejectBlip:
                    // Utterance too short (cough/blip/mic-pop) — drop it silently.
                    state = .idle
                    Logger.voice.debug("🔇 Silence detection: rejected blip (\(String(format: "%.2f", speechDuration), privacy: .public)s speech)")
                }
            case .idle:
                break
            }
        }
    }

    /// Consume the pending first-hypothesis latency anchor: milliseconds from
    /// VAD speech-start to now, or `nil` when no utterance is pending (already
    /// consumed, or the transcript preceded any VAD transition). One-shot per
    /// utterance — the metric means "how long until the engine said ANYTHING".
    func consumeFirstHypothesisLatencyMs() -> Int? {
        guard let since = pendingFirstHypothesisSince else { return nil }
        pendingFirstHypothesisSince = nil
        return Int((now().timeIntervalSince(since) * 1000).rounded())
    }

    // MARK: - Helpers

    private func isExternalAudioRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .carAudio, .airPlay, .headphones, .headsetMic,
        ]
        return outputs.contains { externalPorts.contains($0.portType) }
    }
}
