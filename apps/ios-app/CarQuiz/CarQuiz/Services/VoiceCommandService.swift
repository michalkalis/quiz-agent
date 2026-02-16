//
//  VoiceCommandService.swift
//  CarQuiz
//
//  Continuous on-device speech recognition for hands-free voice commands.
//  Uses iOS 26 SpeechAnalyzer API — runs entirely on-device, no network or cost.
//
//  Audio architecture:
//  - AVAudioEngine.installTap → AsyncStream<AVAudioPCMBuffer> → SpeechTranscriber
//  - Coexists with AudioService's AVAudioRecorder under shared .playAndRecord session
//  - Engine runs continuously; command matching is paused during answer recording
//

import AVFoundation
import Foundation
import Speech

// MARK: - Protocol

/// Protocol for voice command services (testability)
@MainActor
protocol VoiceCommandServiceProtocol: AnyObject, Sendable {
    /// Stream of detected voice commands
    var commands: AsyncStream<VoiceCommand> { get }

    /// Stream of silence detection events (voice activity detection)
    var silenceEvents: AsyncStream<SilenceEvent> { get }

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
}

// MARK: - Implementation (iOS 26+)

@available(iOS 26, *)
@MainActor
final class VoiceCommandService: VoiceCommandServiceProtocol {
    // MARK: - Public API

    let commands: AsyncStream<VoiceCommand>
    let silenceEvents: AsyncStream<SilenceEvent>
    private(set) var listeningState: VoiceCommandListeningState = .disabled

    // MARK: - Private State

    private let commandContinuation: AsyncStream<VoiceCommand>.Continuation
    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation

    private var audioEngine: AVAudioEngine?
    private var listeningTask: Task<Void, Never>?
    private var silenceDetectionTask: Task<Void, Never>?

    /// Current TTS text for echo cancellation (lowercased words)
    private var playbackWords: [String] = []

    /// When true, only "stop" is matched (during answer recording)
    private var isRecordingActive = false

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
    }

    deinit {
        commandContinuation.finish()
        silenceContinuation.finish()
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
            if Config.verboseLogging {
                print("🎙️ VoiceCommandService: No compatible audio format available")
            }
            listeningState = .disabled
            return
        }

        // Set up audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create format converter if needed
        let converter: AVAudioConverter?
        if inputFormat != analyzerFormat {
            converter = AVAudioConverter(from: inputFormat, to: analyzerFormat)
        } else {
            converter = nil
        }

        // Create input sequence for analyzer
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Install tap to capture mic audio and feed to analyzer
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            if let converter {
                let frameCount = AVAudioFrameCount(
                    Double(buffer.frameLength) * analyzerFormat.sampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: analyzerFormat,
                    frameCapacity: frameCount
                ) else { return }

                var error: NSError?
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }

                if error == nil {
                    inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
                }
            } else {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
            }
        }

        do {
            try engine.start()
        } catch {
            if Config.verboseLogging {
                print("🎙️ VoiceCommandService: Failed to start audio engine: \(error)")
            }
            listeningState = .disabled
            return
        }

        if Config.verboseLogging {
            print("🎙️ VoiceCommandService: Listening started")
        }

        // Start silence detection task (processes SpeechDetector results in parallel)
        silenceDetectionTask = Task { [weak self] in
            do {
            for try await result in detector.results {
                guard let self, !Task.isCancelled else { break }

                if result.speechDetected {
                    // Speech is detected
                    switch self.silenceState {
                    case .idle:
                        // First speech detected
                        self.silenceState = .speechActive
                        self.silenceContinuation.yield(.speechStarted)
                        if Config.verboseLogging {
                            print("🔇 Silence detection: speech started")
                        }
                    case .silenceAccumulating:
                        // Speech resumed after brief pause — reset to active
                        self.silenceState = .speechActive
                        if Config.verboseLogging {
                            print("🔇 Silence detection: speech resumed")
                        }
                    case .speechActive:
                        break // Already tracking speech
                    }
                } else {
                    // No speech detected
                    switch self.silenceState {
                    case .speechActive:
                        // Speech just stopped — start accumulating silence
                        self.silenceState = .silenceAccumulating(since: Date())
                        if Config.verboseLogging {
                            print("🔇 Silence detection: silence started after speech")
                        }
                    case .silenceAccumulating(let since):
                        // Check if silence threshold reached
                        let elapsed = Date().timeIntervalSince(since)
                        if elapsed >= Self.silenceThreshold {
                            self.silenceContinuation.yield(.silenceAfterSpeech(duration: elapsed))
                            // Reset to idle after emitting
                            self.silenceState = .idle
                            if Config.verboseLogging {
                                print("🔇 Silence detection: threshold reached (\(String(format: "%.1f", elapsed))s)")
                            }
                        }
                    case .idle:
                        break // No speech yet, ignore silence
                    }
                }
            }
            } catch {
                if Config.verboseLogging {
                    print("🔇 Silence detection error: \(error)")
                }
            }
        }

        // Start analyzer and result processing
        listeningTask = Task { [weak self] in
            do {
                // Start the analyzer with the input sequence (runs in background)
                Task {
                    try? await speechAnalyzer.start(inputSequence: inputSequence)
                }

                // Read transcription results
                for try await result in transcriber.results {
                    guard let self, !Task.isCancelled else { break }

                    let text = String(result.text.characters)
                    let isFinal = result.isFinal

                    // During TTS playback, only check finalized results (reduces echo false triggers)
                    if !self.playbackWords.isEmpty && !isFinal {
                        continue
                    }

                    // Echo cancellation: discard if >60% word overlap with TTS text
                    if self.shouldRejectAsEcho(text) {
                        if Config.verboseLogging {
                            print("🎙️ Echo rejected: \(text)")
                        }
                        continue
                    }

                    // Match command
                    guard let command = VoiceCommand.match(from: text) else { continue }

                    // During recording, only "stop" is allowed
                    if self.isRecordingActive && command != .stop {
                        continue
                    }

                    if Config.verboseLogging {
                        print("🎙️ Voice command detected: \(command.rawValue) (from: \"\(text)\")")
                    }

                    // Flash detected state briefly for UI feedback
                    self.listeningState = .commandDetected(command)
                    self.commandContinuation.yield(command)

                    // Reset to listening after brief delay
                    try? await Task.sleep(for: .milliseconds(500))
                    if !Task.isCancelled {
                        self.listeningState = .listening
                    }
                }
            } catch {
                if Config.verboseLogging {
                    print("🎙️ VoiceCommandService: Transcription error: \(error)")
                }
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

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        analyzer = nil

        listeningState = .disabled

        if Config.verboseLogging {
            print("🎙️ VoiceCommandService: Listening stopped")
        }
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

        if Config.verboseLogging {
            print("🎙️ Recording active: \(active) — \(active ? "only 'stop' allowed" : "all commands enabled")")
        }
    }
}

// MARK: - Mock for Testing

@MainActor
final class MockVoiceCommandService: VoiceCommandServiceProtocol {
    let commands: AsyncStream<VoiceCommand>
    let silenceEvents: AsyncStream<SilenceEvent>
    private let commandContinuation: AsyncStream<VoiceCommand>.Continuation
    private let silenceContinuation: AsyncStream<SilenceEvent>.Continuation

    private(set) var listeningState: VoiceCommandListeningState = .disabled

    // Test inspection
    var isListening = false
    var playbackText: String?
    var recordingActive = false
    var startListeningCallCount = 0
    var stopListeningCallCount = 0

    init() {
        var commandCont: AsyncStream<VoiceCommand>.Continuation!
        self.commands = AsyncStream { commandCont = $0 }
        self.commandContinuation = commandCont

        var silenceCont: AsyncStream<SilenceEvent>.Continuation!
        self.silenceEvents = AsyncStream { silenceCont = $0 }
        self.silenceContinuation = silenceCont
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

    /// Simulate a detected command (for tests)
    func simulateCommand(_ command: VoiceCommand) {
        commandContinuation.yield(command)
    }

    /// Simulate a silence detection event (for tests)
    func simulateSilenceEvent(_ event: SilenceEvent) {
        silenceContinuation.yield(event)
    }

    /// Finish the command stream (for tests)
    func finishCommands() {
        commandContinuation.finish()
    }

    /// Finish the silence events stream (for tests)
    func finishSilenceEvents() {
        silenceContinuation.finish()
    }
}
