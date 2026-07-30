//
//  SilenceDetectionService+Engine.swift
//  Hangs
//
//  The AVAudioEngine + SpeechAnalyzer lifecycle for SilenceDetectionService:
//  pairing the SpeechDetector with the command transcriber from the engine
//  adapter (#120 — SpeechTranscriber or DictationTranscriber, chosen at
//  launch), starting the engine, consuming both result streams, and tearing it
//  all down. Split out of SilenceDetectionService.swift (past the ~300-line
//  cap); the VAD state machine, authorization (#105) and asset preparation stay
//  there, the per-engine transcriber configuration lives in
//  CommandTranscriberAdapter.swift, and the mic side (voice processing + the
//  input tap) is in SilenceDetectionService+InputTap.swift.
//

// @preconcurrency: AVAudio tap/converter closures are not @Sendable. Without
// this, Swift 6 infers @MainActor isolation for a closure passed from a
// @MainActor class and the runtime isolation check crashes when AVAudio invokes
// the tap on its audio thread (see Sentry CARQUIZ-1).
@preconcurrency import AVFoundation
import Foundation
import os
import Speech

extension SilenceDetectionService {
    // MARK: - Lifecycle

    func startListening() async {
        // SINGLE-FLIGHT (#133 audit 1c): `audioEngine == nil` alone is NOT a
        // concurrency check. `audioEngine` is only assigned below the format
        // settle, so it is still nil across every suspension above it
        // (`analyzer.setContext`, `bestAvailableAudioFormat`, the settle retry
        // loop) — a second @MainActor caller entering there passed the same
        // guard and built a second analyzer/engine/tap/task set. Each property
        // then kept whichever call wrote last, and teardown orphaned the other
        // call's still-running engine: the #64 two-engine crash config the
        // pre-`.start()` identity check below (#100.4) only covers for the
        // LATER settle window. Concurrent entry is reachable — see
        // `AudioDeviceState.startSilenceDetectionListening`.
        guard Self.shouldBeginStart(startInFlight: startInFlight, audioEngine: audioEngine) else {
            // Only the re-entrant case is worth a line: "already listening" is a
            // documented no-op every choke-point caller relies on.
            if startInFlight {
                Logger.voice.warning("🔇 SilenceDetection: startListening re-entered while a start was in flight — ignored (#133 1c)")
            }
            return
        }
        startInFlight = true
        defer { startInFlight = false }

        state = .idle
        loggedVolatileThisSegment = false
        pendingFirstHypothesisSince = nil

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

        // iOS 26.3 requires SpeechDetector to be paired with a transcriber
        // module (cannot create a SpeechDetector-only worker). We use
        // detector.results for VAD AND — since the transcriber must exist
        // anyway — its results as the command listener (#77, task 77.5). Which
        // engine and locale, and why its reporting options look the way they do,
        // is the adapter's business (CommandTranscriberAdapter.swift — the #119
        // `.fastResults` measurement rationale lives with the SpeechTranscriber
        // adapter config it justifies). This file only wires modules together.
        let session = transcriberEngine.makeSession()

        let analyzer = SpeechAnalyzer(modules: [session.module, detector])
        self.analyzer = analyzer

        // Vocabulary biasing (#120): fed ONLY to an engine that declares the
        // capability — DictationTranscriber honors contextual strings,
        // SpeechTranscriber ignores them (adapter returns nil; no call at all).
        // Failure is non-fatal: an unbiased recognizer still recognizes, so log
        // and continue rather than degrade to buttons.
        if let vocabulary = transcriberEngine.contextualStrings {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            do {
                try await analyzer.setContext(context)
            } catch {
                SentryLog.warn(
                    "contextual strings rejected",
                    category: .voice,
                    attributes: ["error": error.localizedDescription, "count": vocabulary.count]
                )
            }
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [session.module, detector]
        ) else {
            markCommandsUnavailable(reason: "No compatible audio format for SpeechAnalyzer")
            return
        }

        let engine = AVAudioEngine()
        audioEngine = engine

        let inputNode = engine.inputNode
        if !voiceProcessingUnsupported {
            configureVoiceProcessing(on: inputNode)
        }

        // Read the format AFTER voice processing: enabling VPIO changes the input
        // node's output format, so this must not be hoisted above the call.
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // Real devices (esp. Bluetooth) can return 0 Hz / 0 channels right after
        // AVPlayer playback — retry to let the hardware settle.
        //
        // WHY the budget is seconds, not 600 ms (field fix, 2026-07-26): the FIRST
        // window of every cold launch armed ~1 s after `AppState` activated the
        // session and hit 0 Hz on all five of the founder's launches in Sentry,
        // while the next window on the same device started cleanly — 3 × 200 ms is
        // simply shorter than a cold audio stack takes to come up. The attempt
        // count rides on the telemetry below so the real settle time stops being a
        // guess.
        var settleAttempts = 0
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0 {
            for attempt in 1 ... 12 {
                settleAttempts = attempt
                try? await Task.sleep(for: .milliseconds(250))
                try? AVAudioSession.sharedInstance().setActive(true)
                inputFormat = inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0, inputFormat.channelCount > 0 { break }
                Logger.voice.warning("🔇 SilenceDetection: format retry \(attempt, privacy: .public) — still \(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public)ch")
            }
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                // #105: was console-only (Logger.voice.error), invisible to
                // Sentry and the Settings Status row — fail loud like the
                // other command-listener failure branches.
                markCommandsUnavailable(
                    reason: "Command listener: invalid input format (after \(settleAttempts) settle retries)"
                )
                cleanupAfterStartFailure()
                return
            }
            SentryLog.warn(
                "command mic settled late",
                category: .voice,
                attributes: ["settleAttempts": settleAttempts, "inputHz": inputFormat.sampleRate]
            )
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        installInputTap(
            on: inputNode, format: inputFormat, analyzerFormat: analyzerFormat, continuation: continuation
        )

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

        // Command listener (77.5): consume the adapter-normalized transcripts —
        // volatile hypotheses AND finals, each tagged — and hand them to the
        // view-model's screen-scoped matcher. Defensive (E-fallback): any throw
        // from the transcriber stream flips `commandAvailability` (fail-loud,
        // #77) and ends the loop — VAD is unaffected and the app degrades to the
        // manual mic-button/tap flow rather than crashing.
        transcriptionTask = Task { [weak self] in
            do {
                for try await transcript in session.transcripts {
                    guard let self, !Task.isCancelled else { break }
                    guard !transcript.text.isEmpty else { continue }
                    await MainActor.run { [weak self] in
                        self?.handleEngineTranscript(transcript)
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
            // Enabling voice processing on the input node also enables it on this
            // engine's unconnected OUTPUT node, which the engine can reject. If that
            // is what happened, losing voice commands outright would be strictly
            // worse than the dirty mic we set out to fix — so retry ONCE with voice
            // processing disarmed rather than inferring the cause from
            // `isVoiceProcessingEnabled`, which is true on essentially every attempt
            // and would latch echo cancellation off process-wide on any unrelated
            // failure (see retryStartWithoutVoiceProcessing).
            guard retryStartWithoutVoiceProcessing(
                engine, inputNode: inputNode, analyzerFormat: analyzerFormat, continuation: continuation
            ) else {
                // #105: was console-only (Logger.voice.error), invisible to
                // Sentry and the Settings Status row — fail loud like the other
                // command-listener failure branches.
                markCommandsUnavailable(
                    reason: "Command listener: engine start failed (voiceProcessing: \(inputNode.isVoiceProcessingEnabled), vpRetry: failed)"
                )
                cleanupAfterStartFailure()
                return
            }
            // The retry succeeding is the PROOF that VPIO was the blocker: latch
            // the capability off so the next window (re-armed on the very next
            // TTS/recording transition) comes back with an unprocessed mic instead
            // of paying for this retry every time.
            voiceProcessingUnsupported = true
            SentryLog.warn(
                "voice processing rejected by engine — recovered without it",
                category: .voice,
                attributes: ["error": error.localizedDescription]
            )
        }

        Logger.voice.info("🔇 SilenceDetection: listening started")

        recoverAvailabilityForLiveWindow()

        // Once-per-window proof of WHICH audio path we actually got. Blind spot the
        // build-33 field data could not close: the compatible analyzer formats are
        // [8000, 16000] Hz, so a Bluetooth HFP route at 8 kHz is silently ACCEPTED
        // and degrades recognition quietly, and we have never confirmed which mic
        // the founder's car actually uses — nor whether voice processing survived
        // on it. Engine + locale tags ride on every voice event via
        // VoiceTelemetryContext (#120).
        SentryLog.info(
            "voice command listener started",
            category: .voice,
            attributes: [
                "inputPort": AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "none",
                "inputHz": inputFormat.sampleRate,
                "voiceProcessing": inputNode.isVoiceProcessingEnabled,
            ]
        )
    }

    /// One adapter-normalized transcriber result on the command path: sampled
    /// telemetry, the first-hypothesis latency measurement (#120), and the yield
    /// into the consumer channel.
    ///
    /// SAMPLING: first volatile of each segment plus every final. Volatiles
    /// arrive continuously while any speech is audible, so logging them all
    /// would be thousands of events per drive on a quota'd, rate-limited logger
    /// — and would crowd out the low-frequency "voice cmd matched"/"voice cmd
    /// suppressed" events this pipeline is triaged with. The consumer applies
    /// the SAME rule to its per-transcript drop exits
    /// (`shouldLogDroppedTranscript`). A transcript carrying the one-shot
    /// first-hypothesis measurement is always logged — dropping it would lose
    /// the engine-comparison data point #120 exists for.
    func handleEngineTranscript(_ transcript: CommandTranscript) {
        let firstHypothesisMs = consumeFirstHypothesisLatencyMs()
        if transcript.isFinal || !loggedVolatileThisSegment || firstHypothesisMs != nil {
            var attributes: [String: Any] = [
                "isFinal": transcript.isFinal,
                "len": transcript.text.count,
                "tokens": transcript.text.split(whereSeparator: \.isWhitespace).count,
            ]
            if let firstHypothesisMs { attributes["firstHypothesisMs"] = firstHypothesisMs }
            SentryLog.info("voice transcriber result", category: .voice, attributes: attributes)
        }
        loggedVolatileThisSegment = !transcript.isFinal
        commandChannel.yield(transcript)
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

    /// Whether a fresh `startListening()` may begin: nothing is listening AND no
    /// earlier start is still working through its suspensions (#133 audit 1c).
    /// Both terms are load-bearing — `audioEngine == nil` alone lets a second
    /// caller in during the pre-engine awaits, `!startInFlight` alone lets one in
    /// once an engine is already running. Kept a free function of its inputs for
    /// the same reason as `shouldStartEngine` above: `startListening()` itself
    /// needs a live SpeechAnalyzer/AVAudioEngine, so the guard is only reachable
    /// in tests through the pure form production calls.
    nonisolated static func shouldBeginStart(startInFlight: Bool, audioEngine: AVAudioEngine?) -> Bool {
        !startInFlight && audioEngine == nil
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
        pendingFirstHypothesisSince = nil

        Logger.voice.info("🔇 SilenceDetection: listening stopped")
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
        pendingFirstHypothesisSince = nil
    }
}
