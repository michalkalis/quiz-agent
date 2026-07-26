//
//  SilenceDetectionService+Engine.swift
//  Hangs
//
//  The AVAudioEngine + SpeechAnalyzer lifecycle for SilenceDetectionService:
//  building the paired SpeechDetector / en-US SpeechTranscriber, starting the
//  engine, consuming both result streams, and tearing it all down. Split out of
//  SilenceDetectionService.swift (past the ~300-line cap); the VAD state machine,
//  authorization (#105) and asset preparation stay there, and the mic side
//  (voice processing + the input tap) is in SilenceDetectionService+InputTap.swift.
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
        // VAD AND — since the transcriber must exist anyway — its results as the
        // English command listener (#77, task 77.5). Locale is forced to English
        // (P2: commands are English-only for every user regardless of the Slovak
        // answer path).
        //
        // `.volatileResults` (build-33 field fix, 2026-07-24): with finals-only the
        // transcriber waits for an end-of-speech endpoint, and every repetition
        // EXTENDS the segment and pushes that endpoint further out — the founder
        // says "start", nothing fires, he repeats, and the eventual final ("start"
        // ×7, verbatim in Sentry) lands after the window has already closed.
        // Volatile hypotheses let the consumer act on a command before that
        // endpoint. At-most-one-command-per-utterance is enforced there, so the
        // repeated hypotheses of one utterance cannot double-fire.
        //
        // `.fastResults` REVERSES this change-set's own earlier call, which
        // rejected the flag on the SDK doc string alone ("yielding faster but
        // also less accurate results"). Probing this exact configuration — same
        // Speech.framework, paired SpeechDetector, 100 ms buffers at 1x real
        // time, 12 runs / 8 utterances — measured what the doc string does not
        // say. One word followed by silence:
        //
        //   without it:  NOTHING is emitted until the audio clock reaches ~4 s
        //                (the transcriber's default context window), then the
        //                whole burst lands in one ~70 ms clump — volatile at
        //                4211 ms, final at 4275 ms;
        //   with it:     first hypothesis at 1155 ms, final at 2288 ms.
        //
        // Two consequences, the second decisive. (a) Without the flag the
        // volatile path buys ~10 ms over finals-only — the latency fix this
        // whole change exists for is a no-op. (b) ANY listening window that
        // closes before ~4 s of audio yields NOTHING, not even a final. That is
        // the mechanical explanation for the field data: median command-window
        // lifetime ~1.3 s, and 37 of 56 consumer exits saw ZERO transcripts. The
        // ~4 s is a context-window choice, not compute (fed at 30x real time a
        // 33-result sentence completed in 418 ms), and this flag is precisely
        // what changes it — "reduces result latency by using a smaller context
        // window". Apple's own Preset.progressiveTranscription, "configuration
        // for immediate transcription of live audio", IS volatileResults +
        // fastResults: our use case verbatim.
        //
        // Measurement beats a doc string here, and the accuracy cost is bounded
        // for us in a way it is not for general dictation: a SEVEN-WORD fixed
        // vocabulary behind a 0.72 floor (0.85 for volatiles), destructive
        // commands still waiting for a final, and a wrong early hypothesis
        // superseded rather than acted on.
        //
        // ⚠️ CAVEAT: measured on macOS 26.5, NOT on an iOS 26 device — the
        // Simulator cannot run SpeechTranscriber at all (SFSpeechErrorDomain 1,
        // no installed locales). The same framework and the same doc contract
        // ship on both, but the absolute milliseconds could differ on iPhone ANE
        // hardware. The `sincePrevMs` attribute on every command-path log is what
        // confirms these numbers in the field.
        //
        // Still NOT `.alternativeTranscriptions` (field data shows the primary
        // transcript is already letter-perfect for real command words — N-best
        // would only widen the false-fire surface).
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en_US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
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
        if !voiceProcessingUnsupported {
            configureVoiceProcessing(on: inputNode)
        }

        // Read the format AFTER voice processing: enabling VPIO changes the input
        // node's output format, so this must not be hoisted above the call.
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

        // Command listener (77.5): consume the paired transcriber's English results
        // — volatile hypotheses AND finals, each tagged — and hand them to the
        // view-model's screen-scoped matcher. Defensive (E-fallback): any throw from
        // the transcriber stream flips `commandAvailability` (fail-loud, #77) and
        // ends the loop — VAD is unaffected and the app degrades to the manual
        // mic-button/tap flow rather than crashing.
        transcriptionTask = Task { [weak self] in
            // SAMPLING (see the log below): reset on every final, so each segment
            // contributes at most one volatile event.
            var loggedVolatileThisSegment = false
            do {
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { break }
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    // Pre-filter telemetry: proves on a real device whether the
                    // transcriber emits anything at all (vs. finals never arriving)
                    // — the discriminator the dead-commands diagnosis lacked.
                    // `tokens` is the content-token count: the finals-only build
                    // produced one 7-token final ("start" ×7); volatile results
                    // should now show short hypotheses arriving early instead.
                    //
                    // SAMPLED to the FIRST volatile of each segment plus every
                    // final. Volatiles arrive continuously while any speech is
                    // audible, so logging them all would be thousands of events
                    // per drive on a quota'd, rate-limited logger — and would
                    // crowd out the low-frequency "voice cmd matched"/"voice cmd
                    // suppressed" events this whole change is triaged with. The
                    // consumer applies the SAME rule to its two per-transcript
                    // drop exits (`shouldLogDroppedTranscript`) — sampling only
                    // here would have left that volume in place.
                    if result.isFinal || !loggedVolatileThisSegment {
                        SentryLog.info(
                            "voice transcriber result",
                            category: .voice,
                            attributes: [
                                "isFinal": result.isFinal,
                                "len": text.count,
                                "tokens": text.split(whereSeparator: \.isWhitespace).count,
                            ]
                        )
                    }
                    loggedVolatileThisSegment = !result.isFinal
                    let transcript = CommandTranscript(text: text, isFinal: result.isFinal)
                    await MainActor.run { [weak self] in
                        self?.commandChannel.yield(transcript)
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

        // Once-per-window proof of WHICH audio path we actually got. Blind spot the
        // build-33 field data could not close: `SpeechTranscriber
        // .availableCompatibleAudioFormats` is [8000, 16000], so a Bluetooth HFP
        // route at 8 kHz is silently ACCEPTED and degrades recognition quietly, and
        // we have never confirmed which mic the founder's car actually uses — nor
        // whether voice processing survived on it.
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
}
