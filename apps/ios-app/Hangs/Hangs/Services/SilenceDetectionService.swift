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
import Speech

// MARK: - Events

/// Events emitted by silence detection (SpeechDetector VAD)
enum SilenceEvent: Sendable, Equatable {
    case speechStarted
    case silenceAfterSpeech(duration: TimeInterval)
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

    func startListening() async
    func stopListening()

    /// Signal whether TTS is currently playing (enables barge-in detection).
    func setTTSPlaybackActive(_ active: Bool)
}

// MARK: - Implementation (iOS 26+)

@available(iOS 26, *)
@MainActor
final class SilenceDetectionService: SilenceDetectionServiceProtocol {
    let silenceEvents: AsyncStream<SilenceEvent>
    let bargeInEvents: AsyncStream<Void>
    let commandTranscripts: AsyncStream<String>

    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation
    private let bargeInContinuation: AsyncStream<Void>.Continuation
    private let commandContinuation: AsyncStream<String>.Continuation

    private var audioEngine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var analyzerTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    private var isTTSPlaybackActive = false

    private enum State {
        case idle
        case speechActive
        case silenceAccumulating(since: Date)
    }
    private var state: State = .idle

    /// Silence duration required before emitting `silenceAfterSpeech`.
    private static let silenceThreshold: TimeInterval = 1.5

    private let now: @MainActor () -> Date

    init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now

        var silenceCont: AsyncStream<SilenceEvent>.Continuation!
        self.silenceEvents = AsyncStream { silenceCont = $0 }
        self.silenceContinuation = silenceCont

        var bargeCont: AsyncStream<Void>.Continuation!
        self.bargeInEvents = AsyncStream { bargeCont = $0 }
        self.bargeInContinuation = bargeCont

        var commandCont: AsyncStream<String>.Continuation!
        self.commandTranscripts = AsyncStream { commandCont = $0 }
        self.commandContinuation = commandCont
    }

    deinit {
        silenceContinuation.finish()
        bargeInContinuation.finish()
        commandContinuation.finish()
    }

    // MARK: - Lifecycle

    func startListening() async {
        guard audioEngine == nil else { return }

        state = .idle

        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )

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
            Logger.voice.error("🔇 SilenceDetection: no compatible audio format")
            return
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // Real devices (esp. Bluetooth) can return 0 Hz / 0 channels right after
        // AVPlayer playback — retry briefly to let the hardware settle.
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0 {
            for attempt in 1...3 {
                try? await Task.sleep(for: .milliseconds(200))
                try? AVAudioSession.sharedInstance().setActive(true)
                inputFormat = inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 { break }
                Logger.voice.warning("🔇 SilenceDetection: format retry \(attempt, privacy: .public) — still \(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public)ch")
            }
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                Logger.voice.error("🔇 SilenceDetection: invalid input format, disabling")
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
        self.inputContinuation = continuation

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

        analyzerTask = Task {
            try? await analyzer.start(inputSequence: inputSequence)
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
        // Defensive (E-fallback): any throw from the transcriber stream is logged
        // and ends the loop — VAD is unaffected and the app degrades to the manual
        // mic-button/tap flow rather than crashing.
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
            } catch {
                Logger.voice.error("🎙️ Command transcriber error (degrading to buttons): \(error, privacy: .public)")
            }
        }

        // Give the analyzer task a beat to wire its internal queue up before
        // buffers start flowing from the engine tap.
        try? await Task.sleep(for: .milliseconds(50))

        do {
            try engine.start()
        } catch {
            Logger.voice.error("🔇 SilenceDetection: engine start failed: \(error, privacy: .public)")
            cleanupAfterStartFailure()
            return
        }

        Logger.voice.info("🔇 SilenceDetection: listening started")
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
                state = .speechActive
                silenceContinuation.yield(.speechStarted)
                Logger.voice.debug("🔇 Silence detection: speech started")
            case .silenceAccumulating:
                state = .speechActive
                Logger.voice.debug("🔇 Silence detection: speech resumed")
            case .speechActive:
                break
            }
        } else {
            switch state {
            case .speechActive:
                state = .silenceAccumulating(since: now())
                Logger.voice.debug("🔇 Silence detection: silence started after speech")
            case .silenceAccumulating(let since):
                let elapsed = now().timeIntervalSince(since)
                if elapsed >= Self.silenceThreshold {
                    silenceContinuation.yield(.silenceAfterSpeech(duration: elapsed))
                    state = .idle
                    Logger.voice.debug("🔇 Silence detection: threshold reached (\(String(format: "%.1f", elapsed), privacy: .public)s)")
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

