//
//  VoiceCommandService.swift
//  Hangs
//
//  Continuous on-device speech recognition for hands-free voice commands.
//  Uses iOS 26 SpeechAnalyzer API — runs entirely on-device, no network or cost.
//
//  Audio architecture:
//  - AVAudioEngine.installTap → AsyncStream<AVAudioPCMBuffer> → SpeechTranscriber
//  - Coexists with AudioService's AVAudioRecorder under shared .playAndRecord session
//  - Engine runs continuously; command matching is paused during answer recording
//

// @preconcurrency: AVAudioNodeTapBlock / AVAudioConverterInputBlock are not
// `@Sendable`-annotated in AVFoundation. Without this, Swift 6 strict concurrency
// infers @MainActor isolation for closures passed to `installTap`/`converter.convert`
// in a @MainActor class, and the runtime isolation check fires
// `dispatch_assert_queue(main)` when AVAudio invokes the tap on an audio thread →
// crash. See Sentry CARQUIZ-1 + Swift migration guide "Handle Unmarked Sendable Closures".
@preconcurrency import AVFoundation
import Foundation
import os
import Speech

// MARK: - Protocol

/// Protocol for voice command services (testability)
@MainActor
protocol VoiceCommandServiceProtocol: AnyObject, Sendable {
    /// Stream of detected voice commands
    var commands: AsyncStream<VoiceCommand> { get }

    /// Stream of silence detection events (voice activity detection)
    var silenceEvents: AsyncStream<SilenceEvent> { get }

    /// Stream of barge-in events (speech detected during TTS on external audio route)
    var bargeInEvents: AsyncStream<Void> { get }

    /// Current listening state for UI
    var listeningState: VoiceCommandListeningState { get }

    /// Start listening for voice commands
    func startListening() async

    /// Stop listening and release resources
    func stopListening()

    /// Set the current TTS playback text for echo cancellation.
    /// Pass nil when playback ends.
    func setPlaybackText(_ text: String?)

    /// Suppress all commands except "stop" during answer recording.
    func setRecordingActive(_ active: Bool)

    /// Signal whether TTS is currently playing (for barge-in detection).
    func setTTSPlaybackActive(_ active: Bool)
}

// MARK: - Implementation (iOS 26+)

@available(iOS 26, *)
@MainActor
final class VoiceCommandService: VoiceCommandServiceProtocol {
    // MARK: - Public API

    let commands: AsyncStream<VoiceCommand>
    let silenceEvents: AsyncStream<SilenceEvent>
    let bargeInEvents: AsyncStream<Void>
    private(set) var listeningState: VoiceCommandListeningState = .disabled

    // MARK: - Private State

    private let commandContinuation: AsyncStream<VoiceCommand>.Continuation
    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation
    private let bargeInContinuation: AsyncStream<Void>.Continuation

    private var audioEngine: AVAudioEngine?
    private var listeningTask: Task<Void, Never>?
    private var silenceDetectionTask: Task<Void, Never>?
    private var analyzerTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Current TTS text for echo cancellation (lowercased words)
    private var playbackWords: [String] = []

    /// When true, only "stop" is matched (during answer recording)
    private var isRecordingActive = false

    /// When true, TTS is playing and barge-in detection is active
    private var isTTSPlaybackActive = false

    /// Silence detection state machine
    private enum SilenceState {
        case idle              // No speech detected yet
        case speechActive      // User is speaking
        case silenceAccumulating(since: Date) // Silence started after speech
    }

    private var silenceState: SilenceState = .idle

    /// Silence threshold before auto-submit (seconds)
    private static let silenceThreshold: TimeInterval = 1.5

    // MARK: - Init

    init() {
        var commandCont: AsyncStream<VoiceCommand>.Continuation!
        self.commands = AsyncStream { commandCont = $0 }
        self.commandContinuation = commandCont

        var silenceCont: AsyncStream<SilenceEvent>.Continuation!
        self.silenceEvents = AsyncStream { silenceCont = $0 }
        self.silenceContinuation = silenceCont

        var bargeInCont: AsyncStream<Void>.Continuation!
        self.bargeInEvents = AsyncStream { bargeInCont = $0 }
        self.bargeInContinuation = bargeInCont
    }

    deinit {
        commandContinuation.finish()
        silenceContinuation.finish()
        bargeInContinuation.finish()
    }

    private var analyzer: SpeechAnalyzer?

    // MARK: - Lifecycle

    func startListening() async {
        guard listeningTask == nil else { return }

        listeningState = .listening
        silenceState = .idle

        let locale = Locale(identifier: "en_US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // SpeechDetector for voice activity detection (silence detection)
        let detector = SpeechDetector(
            detectionOptions: .init(sensitivityLevel: .medium),
            reportResults: true
        )

        let speechAnalyzer = SpeechAnalyzer(modules: [transcriber, detector])
        self.analyzer = speechAnalyzer

        // Get the optimal audio format for both modules
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber, detector]
        ) else {
            Logger.voice.error("🎙️ VoiceCommandService: No compatible audio format available")
            listeningState = .disabled
            return
        }

        // Set up audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        var inputFormat = inputNode.outputFormat(forBus: 0)

        // Validate format — on real devices (especially Bluetooth), after AVPlayer playback
        // the audio hardware may not have settled yet, returning 0 Hz / 0 channels.
        // Retry with short delays to let the hardware transition complete.
        if inputFormat.sampleRate <= 0 || inputFormat.channelCount <= 0 {
            for attempt in 1...3 {
                try? await Task.sleep(for: .milliseconds(200))
                try? AVAudioSession.sharedInstance().setActive(true)
                inputFormat = inputNode.outputFormat(forBus: 0)
                if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 { break }
                Logger.voice.warning("🎙️ VoiceCommandService: format retry \(attempt, privacy: .public) — still \(inputFormat.sampleRate, privacy: .public)Hz, \(inputFormat.channelCount, privacy: .public)ch")
            }
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                Logger.voice.error("🎙️ VoiceCommandService: invalid input format after retries, disabling")
                audioEngine = nil
                listeningState = .disabled
                return
            }
        }

        // Create format converter if needed
        let converter: AVAudioConverter?
        if inputFormat != analyzerFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        // Create input sequence for analyzer
        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Snapshot `var inputFormat` to a `let` so the @Sendable tap closure
        // captures an immutable value (not a box into the enclosing var).
        let tapFormat = inputFormat
        let tapAnalyzerFormat = analyzerFormat
        let tapConverter = converter

        // Install tap to capture mic audio and feed to analyzer.
        // `@Sendable` marks the closure non-isolated — critical, otherwise Swift 6
        // infers @MainActor from the enclosing class and the runtime isolation check
        // crashes when AVAudio invokes the tap on its audio thread (Sentry CARQUIZ-1).
        // (engine not started yet — no audio flows until engine.start() below)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable buffer, _ in
            if let tapConverter {
                // Belt-and-suspenders guard against division by zero
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

        // Launch analyzer BEFORE starting engine so it is ready to consume
        // audio buffers the moment they start flowing from the tap.
        analyzerTask = Task {
            try? await speechAnalyzer.start(inputSequence: inputSequence)
        }

        // Start silence detection task (processes SpeechDetector results in parallel)
        // NOTE: The `for try await` loop resumes on the producer's thread (SpeechDetector's queue),
        // so all @MainActor property access must be dispatched back via MainActor.run.
        silenceDetectionTask = Task { [weak self] in
            do {
                for try await result in detector.results {
                    guard let self, !Task.isCancelled else { break }
                    let speechDetected = result.speechDetected
                    await MainActor.run { [weak self] in
                        guard let self else { return }

                        if speechDetected {
                            // Barge-in: if TTS is playing and output is external, interrupt
                            if self.isTTSPlaybackActive && self.isExternalAudioRoute() {
                                self.bargeInContinuation.yield(())
                                Logger.voice.info("🗣️ Barge-in: speech detected during TTS on external route")
                                // Don't update silence state — barge-in handler will reset things
                                return
                            }

                            // Speech is detected
                            switch self.silenceState {
                            case .idle:
                                // First speech detected
                                self.silenceState = .speechActive
                                self.silenceContinuation.yield(.speechStarted)
                                Logger.voice.debug("🔇 Silence detection: speech started")
                            case .silenceAccumulating:
                                // Speech resumed after brief pause — reset to active
                                self.silenceState = .speechActive
                                Logger.voice.debug("🔇 Silence detection: speech resumed")
                            case .speechActive:
                                break // Already tracking speech
                            }
                        } else {
                            // No speech detected
                            switch self.silenceState {
                            case .speechActive:
                                // Speech just stopped — start accumulating silence
                                self.silenceState = .silenceAccumulating(since: Date())
                                Logger.voice.debug("🔇 Silence detection: silence started after speech")
                            case .silenceAccumulating(let since):
                                // Check if silence threshold reached
                                let elapsed = Date().timeIntervalSince(since)
                                if elapsed >= Self.silenceThreshold {
                                    self.silenceContinuation.yield(.silenceAfterSpeech(duration: elapsed))
                                    // Reset to idle after emitting
                                    self.silenceState = .idle
                                    Logger.voice.debug("🔇 Silence detection: threshold reached (\(String(format: "%.1f", elapsed), privacy: .public)s)")
                                }
                            case .idle:
                                break // No speech yet, ignore silence
                            }
                        }
                    }
                }
            } catch {
                Logger.voice.error("🔇 Silence detection error: \(error, privacy: .public)")
            }
        }

        // Give the analyzer task time to initialize its internal queue
        // before the engine starts sending audio buffers.
        // Task.yield() only yields the current time slice — not enough for
        // SpeechAnalyzer's mServiceQueue setup. A short sleep is more reliable.
        try? await Task.sleep(for: .milliseconds(50))

        do {
            try engine.start()
        } catch {
            // Clean up tasks launched before engine.start
            analyzerTask?.cancel()
            analyzerTask = nil
            silenceDetectionTask?.cancel()
            silenceDetectionTask = nil
            inputContinuation?.finish()
            inputContinuation = nil
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine = nil

            Logger.voice.error("🎙️ VoiceCommandService: Failed to start audio engine: \(error, privacy: .public)")
            listeningState = .disabled
            return
        }

        Logger.voice.info("🎙️ VoiceCommandService: Listening started")

        // Start result processing
        // NOTE: The `for try await` loop resumes on the producer's thread (SpeechAnalyzer's queue),
        // so all @MainActor property access must be dispatched back via MainActor.run.
        listeningTask = Task { [weak self] in
            do {

                // Read transcription results
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { break }

                    let text = String(result.text.characters)
                    let isFinal = result.isFinal

                    // Filter and process on MainActor (reads @MainActor properties)
                    let matched: Bool = await MainActor.run { [weak self] in
                        guard let self else { return false }

                        // During TTS playback, only check finalized results (reduces echo false triggers)
                        if !self.playbackWords.isEmpty && !isFinal {
                            return false
                        }

                        // Echo cancellation: discard if >60% word overlap with TTS text
                        if self.shouldRejectAsEcho(text) {
                            Logger.voice.debug("🎙️ Echo rejected: \(text, privacy: .public)")
                            return false
                        }

                        // Match command
                        guard let command = VoiceCommand.match(from: text) else { return false }

                        // During recording, only "stop" is allowed
                        if self.isRecordingActive && command != .stop {
                            return false
                        }

                        Logger.voice.info("🎙️ Voice command detected: \(command.rawValue, privacy: .public) (from: \"\(text, privacy: .public)\")")

                        // Flash detected state briefly for UI feedback
                        self.listeningState = .commandDetected(command)
                        self.commandContinuation.yield(command)
                        return true
                    }

                    guard matched else { continue }

                    // Reset to listening after brief delay
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled {
                        await MainActor.run { [weak self] in
                            self?.listeningState = .listening
                        }
                    }
                }
            } catch {
                Logger.voice.error("🎙️ VoiceCommandService: Transcription error: \(error, privacy: .public)")
            }

            // Cleanup after task ends
            await MainActor.run { [weak self] in
                self?.listeningState = .disabled
            }
        }
    }

    func stopListening() {
        listeningTask?.cancel()
        listeningTask = nil

        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil
        silenceState = .idle

        analyzerTask?.cancel()
        analyzerTask = nil

        // Finish input stream BEFORE removing tap — signals SpeechAnalyzer to stop
        inputContinuation?.finish()
        inputContinuation = nil

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        analyzer = nil

        listeningState = .disabled

        Logger.voice.info("🎙️ VoiceCommandService: Listening stopped")
    }

    // MARK: - Echo Cancellation

    func setPlaybackText(_ text: String?) {
        if let text {
            playbackWords = text.lowercased().split(separator: " ").map(String.init)
        } else {
            playbackWords = []
        }
    }

    /// Returns true if the transcription has >60% word overlap with current TTS text
    private func shouldRejectAsEcho(_ transcription: String) -> Bool {
        guard !playbackWords.isEmpty else { return false }

        let transcriptionWords = Set(transcription.lowercased().split(separator: " ").map(String.init))
        guard !transcriptionWords.isEmpty else { return false }

        let playbackSet = Set(playbackWords)
        let overlap = transcriptionWords.intersection(playbackSet).count
        let overlapRatio = Double(overlap) / Double(transcriptionWords.count)

        return overlapRatio > 0.6
    }

    // MARK: - Recording Suppression

    func setRecordingActive(_ active: Bool) {
        isRecordingActive = active

        Logger.voice.debug("🎙️ Recording active: \(active, privacy: .public) — \(active ? "only 'stop' allowed" : "all commands enabled", privacy: .public)")
    }

    // MARK: - Barge-In Detection

    func setTTSPlaybackActive(_ active: Bool) {
        isTTSPlaybackActive = active

        Logger.voice.debug("🎙️ TTS playback active: \(active, privacy: .public)")
    }

    /// Check if audio output is going to an external device (Bluetooth, CarPlay, AirPlay)
    /// where echo from TTS is unlikely to reach the mic.
    private func isExternalAudioRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .carAudio, .airPlay, .headphones, .headsetMic,
        ]

        return outputs.contains { externalPorts.contains($0.portType) }
    }
}

// MARK: - Mock for Testing

@MainActor
final class MockVoiceCommandService: VoiceCommandServiceProtocol {
    let commands: AsyncStream<VoiceCommand>
    let silenceEvents: AsyncStream<SilenceEvent>
    let bargeInEvents: AsyncStream<Void>
    private let commandContinuation: AsyncStream<VoiceCommand>.Continuation
    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation
    private let bargeInContinuation: AsyncStream<Void>.Continuation

    private(set) var listeningState: VoiceCommandListeningState = .disabled

    // Test inspection
    var isListening = false
    var playbackText: String?
    var recordingActive = false
    var ttsPlaybackActive = false
    var startListeningCallCount = 0
    var stopListeningCallCount = 0

    init() {
        var commandCont: AsyncStream<VoiceCommand>.Continuation!
        self.commands = AsyncStream { commandCont = $0 }
        self.commandContinuation = commandCont

        var silenceCont: AsyncStream<SilenceEvent>.Continuation!
        self.silenceEvents = AsyncStream { silenceCont = $0 }
        self.silenceContinuation = silenceCont

        var bargeInCont: AsyncStream<Void>.Continuation!
        self.bargeInEvents = AsyncStream { bargeInCont = $0 }
        self.bargeInContinuation = bargeInCont
    }

    func startListening() async {
        isListening = true
        listeningState = .listening
        startListeningCallCount += 1
    }

    func stopListening() {
        isListening = false
        listeningState = .disabled
        stopListeningCallCount += 1
    }

    func setPlaybackText(_ text: String?) {
        playbackText = text
    }

    func setRecordingActive(_ active: Bool) {
        recordingActive = active
    }

    func setTTSPlaybackActive(_ active: Bool) {
        ttsPlaybackActive = active
    }

    /// Simulate a detected command (for tests)
    func simulateCommand(_ command: VoiceCommand) {
        commandContinuation.yield(command)
    }

    /// Simulate a silence detection event (for tests)
    func simulateSilenceEvent(_ event: SilenceEvent) {
        silenceContinuation.yield(event)
    }

    /// Simulate a barge-in event (for tests)
    func simulateBargeIn() {
        bargeInContinuation.yield(())
    }

    /// Finish the command stream (for tests)
    func finishCommands() {
        commandContinuation.finish()
    }

    /// Finish the silence events stream (for tests)
    func finishSilenceEvents() {
        silenceContinuation.finish()
    }

    /// Finish the barge-in events stream (for tests)
    func finishBargeInEvents() {
        bargeInContinuation.finish()
    }
}
