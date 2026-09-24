//
//  SilenceDetectionService.swift
//  Hangs
//
//  Continuous on-device voice activity detection (since #185 track A the
//  band-limited `EnergyVAD` on the mic tap — Apple's SpeechDetector reports no
//  speech results), plus the command transcriber that feeds voice commands
//  (#77). Since
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
//  SilenceDetectionService+Engine.swift, the speech state machine and the
//  per-recording detection session in +VAD.swift; this file keeps the state,
//  the protocol, authorization (#105) and asset preparation.
//

// @preconcurrency: AVAudio tap/converter closures are not @Sendable. Without this,
// Swift 6 infers @MainActor isolation for a closure passed from a @MainActor class
// and the runtime isolation check crashes when AVAudio invokes the tap on its
// audio thread (see Sentry CARQUIZ-1). The tap itself now lives in
// SilenceDetectionService+Engine.swift, which carries the same annotation.
@preconcurrency import AVFoundation
import Clocks
import Foundation
import os

// @preconcurrency: same crash class as AVFoundation above — the legacy
// SFSpeechRecognizer.requestAuthorization completion fires on a TCC background
// queue; without this the inferred @MainActor isolation check traps at launch.
@preconcurrency import Speech

// MARK: - Events

/// Events emitted by silence detection (the on-device VAD, see +VAD.swift)
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
    /// #184 n-best: the recognizer's other hypotheses for this same audio, best
    /// first, empty on an engine that does not report them. A car-noise final
    /// often ranks a near-miss first and the real command second, so the
    /// consumer retries these when the primary text matches nothing — FINALS
    /// only (a volatile is revisable already; widening it with alternatives
    /// would multiply the false-fire surface).
    let alternatives: [String]

    // `nonisolated`: the bridging task that builds these runs off the main
    // actor, and the module's default isolation would otherwise pin the init.
    nonisolated init(text: String, isFinal: Bool, alternatives: [String] = []) {
        self.text = text
        self.isFinal = isFinal
        self.alternatives = alternatives
    }
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

    /// #185 track A: the mic level of every tap buffer while the engine runs —
    /// the signal behind a "the mic hears you" ring. No UI consumes it yet.
    func makeInputLevelStream() -> AsyncStream<InputLevel>

    /// #185 track A: one answer recording's detection session. `begin` resets
    /// ALL speech-detection state (noise floor, speech state, silence timer —
    /// nothing from the command window may leak into the answer, H3) and sets
    /// the blip bar (`minSpeechDuration`, lower for multiple choice); `end`
    /// closes it and returns what the detectors saw, for the stop telemetry.
    func beginAnswerDetection(minSpeechDuration: TimeInterval)
    func endAnswerDetection() -> AnswerDetectionReport

    /// Whether the 5 s no-speech window may end the recording in progress —
    /// only when a detector demonstrably works and heard nothing (#185).
    var noSpeechWindowVerdict: NoSpeechWindowVerdict { get }

    func startListening() async
    func stopListening()

    /// #175: make the command recognizer match the quiz language. No-op when
    /// it already does; deferred (retried at the next window) while a
    /// listening window is open. Called before every window start.
    func setCommandEngine(_ selection: CommandEngineSelection) async

    /// Signal whether TTS is currently playing (enables barge-in detection).
    func setTTSPlaybackActive(_ active: Bool)

    /// #184 track B: the shared mic engine doubles as the ANSWER recorder. The
    /// batch answer path needs to know whether an engine is live (or coming up)
    /// before it arms a capture, because a start that never happened means no
    /// audio will ever arrive.
    var isListening: Bool { get }
    var isStartingListening: Bool { get }

    /// #185 track C: the live engine's voice processing (the policy's mode,
    /// whether the input node armed it, the output it was decided on), `nil`
    /// while no engine runs. Recording metadata and route-change handling
    /// read it.
    var voiceProcessingStatus: VoiceProcessingStatus? { get }

    /// Sample rate of the 16-bit mono PCM the answer sink receives (the
    /// analyzer format: 16 kHz, or 8 kHz on a narrowband Bluetooth route).
    var answerAudioSampleRate: Double { get }

    /// Tee the tap's post-voice-processing samples into `sink` (called on the
    /// audio thread) while an answer is being recorded; `nil` stops the tee.
    /// One engine, one tap: the VAD and the recording see the SAME audio, and
    /// no second mic client (#64/#77 two-engine class) ever opens.
    func setAnswerAudioSink(_ sink: (@Sendable (Data) -> Void)?)
}

// MARK: - Implementation

@MainActor
final class SilenceDetectionService: SilenceDetectionServiceProtocol {
    // Per-acquisition stream channels (dead-voice-commands fix): each consumer
    // re-arm gets a fresh AsyncStream, so cancelling a replaced consumer can
    // never starve the current one. See StreamChannel.swift for the invariant.
    let silenceChannel = StreamChannel<SilenceEvent>()
    let bargeInChannel = StreamChannel<Void>()
    let commandChannel = StreamChannel<CommandTranscript>()
    private let commandAvailabilityChannel = StreamChannel<VoiceCommandAvailability>()
    let inputLevelChannel = StreamChannel<InputLevel>()

    func makeSilenceEventStream() -> AsyncStream<SilenceEvent> { silenceChannel.makeStream() }
    func makeBargeInStream() -> AsyncStream<Void> { bargeInChannel.makeStream() }
    func makeCommandTranscriptStream() -> AsyncStream<CommandTranscript> { commandChannel.makeStream() }
    func makeCommandAvailabilityStream() -> AsyncStream<VoiceCommandAvailability> { commandAvailabilityChannel.makeStream() }
    func makeInputLevelStream() -> AsyncStream<InputLevel> { inputLevelChannel.makeStream() }

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
    /// #185: the tap's per-buffer levels, drained on the main actor into the VAD.
    var levelTask: Task<Void, Never>?
    var levelContinuation: AsyncStream<InputLevelSample>.Continuation?

    /// Whether a `startListening()` is between its entry guard and its return
    /// (#133 audit 1c). `audioEngine` cannot express this: it stays nil across
    /// every suspension in the first half of `startListening()` (the analyzer is
    /// built first, the engine only after the input format settles), so a second
    /// caller landing in that window passed the `audioEngine == nil` guard and
    /// built a SECOND analyzer/engine/tap — each property then kept whichever
    /// call wrote last and teardown orphaned the other one (the #64 two-engine
    /// crash config). Set/cleared by `startListening()` only.
    var startInFlight = false

    var isListening: Bool { audioEngine != nil }
    var isStartingListening: Bool { startInFlight }

    /// #185 track C — see the protocol. Written by the +Engine lifecycle.
    var voiceProcessingStatus: VoiceProcessingStatus?

    /// #184 track B — see the protocol. Set when the tap is installed.
    var answerAudioSampleRate: Double = 16000

    /// The answer tee (#184). Lock-held so the audio-thread tap can read it
    /// without an actor hop; written only via `setAnswerAudioSink`.
    let answerAudioSink = OSAllocatedUnfairLock<(@Sendable (Data) -> Void)?>(initialState: nil)

    func setAnswerAudioSink(_ sink: (@Sendable (Data) -> Void)?) {
        answerAudioSink.withLock { $0 = sink }
    }

    /// The engine seam (#120): constructs, configures and normalizes the
    /// concrete transcriber. Follows the quiz language (#175) — swapped only
    /// between listening windows by `setCommandEngine`; everything below reads
    /// capabilities off it instead of naming an engine. Internal (not
    /// `private(set)`) only because the writer lives in the +Assets extension.
    var transcriberEngine: CommandTranscriberAdapter

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
    var pendingFirstHypothesisSince: AnyClock<Duration>.Instant?

    var isTTSPlaybackActive = false

    // MARK: Speech detection (#185 track A — the logic lives in +VAD.swift)

    /// The band-limited level detector fed by the tap.
    var energyVAD = EnergyVAD()
    /// Each detector's current opinion; speech is active when EITHER says so.
    var energySpeaking = false
    var speechDetectorSpeaking = false
    /// Whether this window's analyzer has a SpeechDetector paired
    /// (`VADTuning.commandGateSensitivity`) — its result count is reported
    /// only then.
    var speechDetectorPaired = false
    /// When the last level buffer arrived — a detector with no recent audio is
    /// not "hearing silence", it is not hearing anything.
    var lastLevelAt: AnyClock<Duration>.Instant?
    /// The clock-driven silence check (#185): fires at the hangover deadline
    /// even when no detector event arrives to re-evaluate the silence.
    var silenceCheckTask: Task<Void, Never>?
    /// The answer recording in progress, if any (`beginAnswerDetection`).
    var answerSession: AnswerDetectionSession?

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
        case speechActive(since: AnyClock<Duration>.Instant)
        /// Silence is accumulating after an utterance. `speechStart` is carried
        /// so the blip guard knows how long the preceding speech lasted.
        case silenceAccumulating(speechStart: AnyClock<Duration>.Instant, since: AnyClock<Duration>.Instant)
    }

    var state: State = .idle

    let clock: AnyClock<Duration>

    /// Requests speech-recognition authorization and returns the resulting
    /// status. Defaults to the real `SFSpeechRecognizer` dialog; tests inject
    /// a stub so the decision logic can run without the system prompt (#105).
    /// Internal, not `private` — consumed by the +Assets sibling-file extension.
    let authorizationProvider: () async -> SFSpeechRecognizerAuthorizationStatus

    init(
        clock: AnyClock<Duration> = .continuous,
        authorizationProvider: (() async -> SFSpeechRecognizerAuthorizationStatus)? = nil,
        engine: CommandTranscriberAdapter? = nil,
        selection: CommandEngineSelection = .speechEnglish
    ) {
        self.clock = clock
        self.authorizationProvider = authorizationProvider ?? Self.requestSystemAuthorization
        let resolvedEngine = engine ?? selection.makeAdapter()
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
        inputLevelChannel.finish()
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

    //
    // handleSpeechDetectorResult() / handleInputLevel() — the speech state
    // machine, the clock-driven silence check and the per-recording detection
    // session — live in SilenceDetectionService+VAD.swift.
}
