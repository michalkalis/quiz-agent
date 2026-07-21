//
//  SilenceDetectionService.swift
//  Hangs
//
//  Continuous on-device voice activity detection via iOS 26 SpeechDetector.
//  Emits two streams:
//    • `silenceEvents`  — speechStarted / silenceAfterSpeech (drives auto-stop).
//    • `bargeInEvents`  — speech detected during TTS on an external audio route.
//
//  Replaced the former VoiceCommandService. We kept only the VAD half —
//  the SpeechTranscriber-based command matching was English-only, unreliable
//  for the Slovak user, and duplicated by silence auto-submit + auto-confirm.
//

// @preconcurrency: AVAudio tap/converter closures are not @Sendable. Without this,
// Swift 6 infers @MainActor isolation for a closure passed from a @MainActor class
// and the runtime isolation check crashes when AVAudio invokes the tap on its
// audio thread (see Sentry CARQUIZ-1).
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

// MARK: - Protocol

@MainActor
protocol SilenceDetectionServiceProtocol: AnyObject, Sendable {
    var silenceEvents: AsyncStream<SilenceEvent> { get }
    var bargeInEvents: AsyncStream<Void> { get }

    /// Finalized English transcripts from the paired command transcriber (#77,
    /// task 77.5). The SpeechDetector VAD requires a paired SpeechTranscriber
    /// (CARQUIZ-3); rather than leave that transcriber idle we re-locale it to
    /// English (P2 — commands are English-only for all users) and surface its
    /// finalized results here for the screen-scoped `VoiceCommandMatcher`. The
    /// answer path stays Slovak ElevenLabs — this stream is command-only and is
    /// consumed only inside a listening window (never during recording).
    var commandTranscripts: AsyncStream<String> { get }

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
    var commandAvailabilityUpdates: AsyncStream<VoiceCommandAvailability> { get }

    func startListening() async
    func stopListening()

    /// Signal whether TTS is currently playing (enables barge-in detection).
    func setTTSPlaybackActive(_ active: Bool)
}

// MARK: - Implementation

@MainActor
final class SilenceDetectionService: SilenceDetectionServiceProtocol {
    let silenceEvents: AsyncStream<SilenceEvent>
    let bargeInEvents: AsyncStream<Void>
    let commandTranscripts: AsyncStream<String>
    let commandAvailabilityUpdates: AsyncStream<VoiceCommandAvailability>

    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation
    private let bargeInContinuation: AsyncStream<Void>.Continuation
    private let commandContinuation: AsyncStream<String>.Continuation
    private let commandAvailabilityContinuation: AsyncStream<VoiceCommandAvailability>.Continuation

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var analyzerTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    private var isTTSPlaybackActive = false

    /// Fail-loud command availability (#77). Written by `prepareAssets()` and by
    /// every failure path that previously swallowed its error silently. Each
    /// mutation is pushed to `commandAvailabilityUpdates` so an observer (the
    /// view-model's `@Published` mirror) re-renders reactively (#96 S2). `didSet`
    /// does not fire for the initializer's value — observers see changes only.
    private(set) var commandAvailability: VoiceCommandAvailability = .unknown {
        didSet { commandAvailabilityContinuation.yield(commandAvailability) }
    }

    private enum State {
        case idle
        /// Speech is active; `since` marks when the utterance began so the
        /// min-speech-duration blip guard (77.11) can measure it.
        case speechActive(since: Date)
        /// Silence is accumulating after an utterance. `speechStart` is carried
        /// so the blip guard knows how long the preceding speech lasted.
        case silenceAccumulating(speechStart: Date, since: Date)
    }

    private var state: State = .idle

    private let now: @MainActor () -> Date

    /// Requests speech-recognition authorization and returns the resulting
    /// status. Defaults to the real `SFSpeechRecognizer` dialog; tests inject
    /// a stub so the decision logic can run without the system prompt (#105).
    private let authorizationProvider: () async -> SFSpeechRecognizerAuthorizationStatus

    init(
        now: @escaping @MainActor () -> Date = { Date() },
        authorizationProvider: (() async -> SFSpeechRecognizerAuthorizationStatus)? = nil
    ) {
        self.now = now
        self.authorizationProvider = authorizationProvider ?? Self.requestSystemAuthorization

        var silenceCont: AsyncStream<SilenceEvent>.Continuation!
        silenceEvents = AsyncStream { silenceCont = $0 }
        silenceContinuation = silenceCont

        var bargeCont: AsyncStream<Void>.Continuation!
        bargeInEvents = AsyncStream { bargeCont = $0 }
        bargeInContinuation = bargeCont

        var commandCont: AsyncStream<String>.Continuation!
        commandTranscripts = AsyncStream { commandCont = $0 }
        commandContinuation = commandCont

        var availabilityCont: AsyncStream<VoiceCommandAvailability>.Continuation!
        commandAvailabilityUpdates = AsyncStream { availabilityCont = $0 }
        commandAvailabilityContinuation = availabilityCont
    }

    deinit {
        silenceContinuation.finish()
        bargeInContinuation.finish()
        commandContinuation.finish()
        commandAvailabilityContinuation.finish()
    }

    // MARK: - Authorization (#105)

    /// Requests the OS speech-recognition permission and then, if granted,
    /// proceeds into the existing asset-prepare flow. #105: the app declared
    /// `NSSpeechRecognitionUsageDescription` but never actually called
    /// `SFSpeechRecognizer.requestAuthorization` anywhere — a denied/never-asked
    /// permission silently strands the command listener with `.unknown`
    /// availability forever. Called once from AppState at launch, exactly like
    /// `prepareAssets()` used to be called alone; safe to re-enter (guarded by
    /// the same `.unknown` check inside `prepareAssets()`).
    func requestAuthorizationAndPrepareAssets() async {
        let status = await authorizationProvider()
        switch Self.authorizationDecision(for: status) {
        case .proceed:
            await prepareAssets()
        case let .unavailable(reason):
            markCommandsUnavailable(reason: reason)
        }
    }

    /// Pure status → decision mapping (#105), kept separate from the async
    /// system call so the decision logic is unit-testable without triggering
    /// the real permission dialog.
    enum AuthorizationDecision: Sendable, Equatable {
        case proceed
        case unavailable(reason: String)
    }

    nonisolated static func authorizationDecision(for status: SFSpeechRecognizerAuthorizationStatus) -> AuthorizationDecision {
        switch status {
        case .authorized, .notDetermined:
            return .proceed
        case .denied, .restricted:
            return .unavailable(
                reason: "Speech recognition permission denied — enable in iOS Settings > Privacy & Security > Speech Recognition"
            )
        @unknown default:
            return .unavailable(
                reason: "Speech recognition permission denied — enable in iOS Settings > Privacy & Security > Speech Recognition"
            )
        }
    }

    /// The real system dialog, bridged to async. `SFSpeechRecognizer` is the
    /// only authorization API for this stack — the iOS 26 SpeechAnalyzer/
    /// SpeechTranscriber/AssetInventory types expose no authorization API of
    /// their own (verified against the SDK headers/.swiftinterface, #105).
    /// `nonisolated` + `@Sendable` completion: the TCC callback fires on a
    /// background XPC queue; without both, the closure inherits @MainActor
    /// isolation from the enclosing class and the Swift 6 runtime isolation
    /// check traps at launch (same crash class as the AVAudio tap, CARQUIZ-1).
    private nonisolated static func requestSystemAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Asset preparation (#77 device fix)

    /// One-time launch check/install of the on-device en-US SpeechTranscriber
    /// model assets. Without installed assets the transcriber never produces a
    /// result on a real device — the root cause of "commands never worked".
    /// Called once from AppState at launch (NOT from startListening, which runs
    /// per listening window); safe to re-enter (no-op after the first resolution).
    func prepareAssets() async {
        guard case .unknown = commandAvailability else { return }

        let locale = Locale(identifier: "en-US")
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            markCommandsUnavailable(
                reason: "en-US not in SpeechTranscriber.supportedLocales (\(supported.count) supported)"
            )
            return
        }

        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            commandAvailability = .ready
            // Mirror to Sentry (#96 P2.3) so the founder's device confirms the
            // recognizer assets are present at launch — the pre-condition for
            // commands working at all.
            SentryLog.info("Voice command assets ready", category: .voice, attributes: ["source": "already-installed"])
            return
        }

        commandAvailability = .installingAssets
        SentryLog.info("Voice command assets installing", category: .voice, attributes: ["locale": "en-US"])
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            commandAvailability = .ready
            SentryLog.info("Voice command assets ready", category: .voice, attributes: ["source": "installed"])
        } catch {
            markCommandsUnavailable(reason: "Asset install failed: \(error.localizedDescription)")
        }
    }

    /// Fail-loud seam shared by all failure paths: flips the flag the UI reads
    /// and logs at error level so degrading to buttons is never silent.
    func markCommandsUnavailable(reason: String) {
        commandAvailability = .unavailable(reason: reason)
        // Mirror to Sentry (#96 P2) so a device that silently degrades to
        // buttons — the founder's exact symptom — surfaces in /check-crashes.
        SentryLog.error("Voice commands unavailable", category: .voice, attributes: ["reason": reason])
    }

    // MARK: - Lifecycle

    func startListening() async {
        guard audioEngine == nil else { return }

        state = .idle

        // Sensitivity centralised in VADTuning (77.11): .low for road noise.
        let detector: SpeechDetector
        switch VADTuning.detectorSensitivity {
        case .low:
            detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .low), reportResults: true)
        case .medium:
            detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        case .high:
            detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .high), reportResults: true)
        }

        // iOS 26.3 requires SpeechDetector to be paired with a SpeechTranscriber
        // (cannot create a SpeechDetector-only worker). We use detector.results for
        // VAD AND — since the transcriber must exist anyway — its finalized results
        // as the English command listener (#77, task 77.5). Locale is forced to
        // English (P2: commands are English-only for every user regardless of the
        // Slovak answer path). `reportingOptions: []` = finalized results only, which
        // is exactly what the screen-scoped command matcher wants.
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en_US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber, detector]
        ) else {
            markCommandsUnavailable(reason: "No compatible audio format for SpeechAnalyzer")
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // Real devices (esp. Bluetooth) can return 0 Hz / 0 channels right after
        // AVPlayer playback — retry briefly to let the hardware settle.
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0 {
            for attempt in 1 ... 3 {
                try? await Task.sleep(for: .milliseconds(200))
                try? AVAudioSession.sharedInstance().setActive(true)
                inputFormat = inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 { break }
                Logger.voice.warning("🔇 SilenceDetection: format retry \(attempt, privacy: .public) — still \(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public)ch")
            }
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                // #105: was console-only (Logger.voice.error), invisible to
                // Sentry and the Settings Status row — fail loud like the
                // other command-listener failure branches.
                markCommandsUnavailable(reason: "Command listener: invalid input format")
                cleanupAfterStartFailure()
                return
            }
        }

        let converter: AVAudioConverter?
        if inputFormat != analyzerFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let tapFormat = inputFormat
        let tapAnalyzerFormat = analyzerFormat
        let tapConverter = converter

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable buffer, _ in
            if let tapConverter {
                guard tapFormat.sampleRate > 0 else { return }
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * tapAnalyzerFormat.sampleRate / tapFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: tapAnalyzerFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                tapConverter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error == nil {
                    continuation.yield(AnalyzerInput(buffer: convertedBuffer))
                }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }

        // Fail loud (#77): a swallowed throw here was the silent death of both
        // VAD and voice commands on device. Cancellation (normal teardown via
        // stopListening) is not a failure.
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.start(inputSequence: inputSequence)
            } catch is CancellationError {
                // normal stopListening() teardown
            } catch {
                self?.markCommandsUnavailable(reason: "SpeechAnalyzer start failed: \(error.localizedDescription)")
            }
        }

        // NOTE: SpeechDetector delivers results on its own queue; route back to
        // @MainActor before touching our state.
        detectionTask = Task { [weak self] in
            do {
                for try await result in detector.results {
                    guard let self, !Task.isCancelled else { break }
                    let speechDetected = result.speechDetected
                    await MainActor.run { [weak self] in
                        self?.handleSpeechDetectorResult(speechDetected: speechDetected)
                    }
                }
            } catch {
                Logger.voice.error("🔇 SilenceDetection error: \(error, privacy: .public)")
            }
        }

        // Command listener (77.5): consume the paired transcriber's FINALIZED
        // English results and hand them to the view-model's screen-scoped matcher.
        // Defensive (E-fallback): any throw from the transcriber stream flips
        // `commandAvailability` (fail-loud, #77) and ends the loop — VAD is
        // unaffected and the app degrades to the manual mic-button/tap flow
        // rather than crashing.
        transcriptionTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { break }
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    await MainActor.run { [weak self] in
                        _ = self?.commandContinuation.yield(text)
                    }
                }
            } catch is CancellationError {
                // normal stopListening() teardown
            } catch {
                await MainActor.run { [weak self] in
                    self?.markCommandsUnavailable(reason: "Command transcriber failed: \(error.localizedDescription)")
                }
            }
        }

        // Give the analyzer task a beat to wire its internal queue up before
        // buffers start flowing from the engine tap.
        try? await Task.sleep(for: .milliseconds(50))

        // #100.4: a stopListening() (or a superseding startListening()) racing this
        // sleep nils/replaces self.audioEngine. Starting the stale local `engine`
        // anyway would orphan a running engine stopListening() can never reach
        // again — the #64 two-engine crash config. stopListening() already tore
        // down this engine's tap/state if it ran, so bailing here is enough.
        guard Self.shouldStartEngine(engine, tracking: audioEngine) else {
            Logger.voice.warning("🔇 SilenceDetection: startListening superseded during startup settle window, not starting engine")
            return
        }

        do {
            try engine.start()
        } catch {
            // #105: was console-only (Logger.voice.error), invisible to
            // Sentry and the Settings Status row — fail loud like the other
            // command-listener failure branches.
            markCommandsUnavailable(reason: "Command listener: engine start failed")
            cleanupAfterStartFailure()
            return
        }

        Logger.voice.info("🔇 SilenceDetection: listening started")
    }

    /// Whether the engine we're about to `.start()` (after the analyzer-queue
    /// settle sleep above) is still the one `self.audioEngine` tracks. Pure
    /// identity check — no engine object is touched — so it's unit-testable
    /// without a live SpeechAnalyzer/AVAudioEngine pipeline (real engines "can't
    /// run headlessly", see SharedEngineTests). #100.4: production code passes
    /// `self.audioEngine` as `current`; this stays a free function of its inputs
    /// so tests can drive the exact race (nil / same / different engine) directly.
    nonisolated static func shouldStartEngine(_ engine: AVAudioEngine, tracking current: AVAudioEngine?) -> Bool {
        current === engine
    }

    func stopListening() {
        detectionTask?.cancel()
        detectionTask = nil

        transcriptionTask?.cancel()
        transcriptionTask = nil

        analyzerTask?.cancel()
        analyzerTask = nil

        inputContinuation?.finish()
        inputContinuation = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        analyzer = nil
        state = .idle

        Logger.voice.info("🔇 SilenceDetection: listening stopped")
    }

    func setTTSPlaybackActive(_ active: Bool) {
        isTTSPlaybackActive = active
    }

    // MARK: - Result Handling

    func handleSpeechDetectorResult(speechDetected: Bool) {
        if speechDetected {
            // Barge-in: only when TTS is playing on an external audio route
            // (echo from the device speaker would trigger false positives).
            if isTTSPlaybackActive && isExternalAudioRoute() {
                bargeInContinuation.yield(())
                Logger.voice.info("🗣️ Barge-in: speech detected during TTS on external route")
                return
            }

            switch state {
            case .idle:
                state = .speechActive(since: now())
                silenceContinuation.yield(.speechStarted)
                Logger.voice.debug("🔇 Silence detection: speech started")
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
                    silenceContinuation.yield(.silenceAfterSpeech(duration: silenceElapsed))
                    state = .idle
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

    // MARK: - Helpers

    private func cleanupAfterStartFailure() {
        detectionTask?.cancel()
        detectionTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        analyzerTask?.cancel()
        analyzerTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        analyzer = nil
    }

    private func isExternalAudioRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .carAudio, .airPlay, .headphones, .headsetMic,
        ]
        return outputs.contains { externalPorts.contains($0.portType) }
    }
}
