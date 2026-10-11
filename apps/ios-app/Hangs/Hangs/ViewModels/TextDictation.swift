//
//  TextDictation.swift
//  Hangs
//
//  Reusable "dictate into a text field" engine: the #109 feedback dictation
//  without its WAV tee, as one object a form can own. Used by the custom-pack
//  prompt; the feedback sheet and the rating panel still carry their own copies
//  (same shape — candidates to move onto this).
//
//  Runs on the SHARED `AudioService` + `ElevenLabsSTT` instances passed in via
//  `FeedbackVoiceServices`, never fresh ones: a second AVAudioEngine is the
//  #64/#77 crash class. Each VAD-committed segment is handed to `onSegment`, so
//  the owner appends it to its own editable text and dictation keeps going
//  until the user stops it.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import os

@MainActor
final class TextDictation: ObservableObject {
    enum MicState: Equatable {
        case idle
        case dictating
        case denied
    }

    @Published private(set) var micState: MicState = .idle
    /// The in-flight (uncommitted) words, shown live while the user speaks.
    @Published private(set) var partialTranscript: String = ""
    /// Set when the cap auto-stops a dictation, so the UI can say why.
    @Published private(set) var didHitDictationCap = false

    /// Hard cap for one dictation. Injectable so tests drive the auto-stop.
    var maxDictationSeconds: TimeInterval = Config.feedbackDictationCapSecs

    private let voice: FeedbackVoiceServices?
    private let networkService: NetworkServiceProtocol?
    private var onSegment: (String) -> Void = { _ in }
    private var eventListenerTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    /// Nil `voice` (previews, snapshots, tests without audio) means no mic UI.
    init(voice: FeedbackVoiceServices?, networkService: NetworkServiceProtocol?) {
        self.voice = voice
        self.networkService = networkService
    }

    var isAvailable: Bool { voice?.sttService != nil && networkService != nil }
    var isDictating: Bool { micState == .dictating }
    /// The quiz holds the shared mic — dictation stays blocked (single engine).
    var isBlockedByQuizRecording: Bool { voice?.isQuizRecording() ?? false }
    var micButtonDisabled: Bool { isBlockedByQuizRecording || micState == .denied }

    /// Join a committed segment onto existing text with a single space.
    static func appending(_ segment: String, to text: String) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return text }
        if text.isEmpty { return segment }
        if text.last == " " || text.last == "\n" { return text + segment }
        return text + " " + segment
    }

    func toggle(languageCode: String, onSegment: @escaping (String) -> Void) async {
        switch micState {
        case .dictating:
            await stop()
        case .idle, .denied:
            await start(languageCode: languageCode, onSegment: onSegment)
        }
    }

    /// Begin streaming dictation in `languageCode` on the shared services.
    func start(languageCode: String, onSegment: @escaping (String) -> Void) async {
        guard let voice, let sttService = voice.sttService, let networkService else { return }
        // Single-engine guard: never open the mic while the quiz holds it.
        guard !voice.isQuizRecording(), micState != .dictating else { return }

        // Typing always works, so a denial only flips the mic to `.denied`.
        guard await voice.audioService.requestMicrophonePermission() else {
            micState = .denied
            Logger.audio.info("🎙️ Text dictation blocked — mic permission denied")
            return
        }

        self.onSegment = onSegment
        partialTranscript = ""
        didHitDictationCap = false

        do {
            let token = try await networkService.fetchElevenLabsToken()
            try await sttService.connect(token: token, languageCode: languageCode)
            startEventListener(sttService)

            await voice.audioService.prepareForRecording()

            // Re-check after the awaits: a quiz timer under the sheet could have
            // taken the shared mic in that window.
            guard !voice.isQuizRecording() else {
                eventListenerTask?.cancel()
                eventListenerTask = nil
                await sttService.disconnect()
                partialTranscript = ""
                micState = .idle
                Logger.stt.info("🎙️ Text dictation aborted — quiz took the mic during setup")
                return
            }

            let stt = sttService
            try await voice.audioService.startStreamingRecording { pcmData in
                Task { try? await stt.sendAudioChunk(pcmData) }
            }

            micState = .dictating
            startCapTimer()
            registerInterruptionObserver()
            Logger.stt.info("🎙️ Text dictation started")
        } catch {
            eventListenerTask?.cancel()
            eventListenerTask = nil
            voice.audioService.stopStreamingRecording()
            await sttService.disconnect()
            partialTranscript = ""
            micState = .idle
            Logger.stt.warning("⚠️ Text dictation failed to start: \(error, privacy: .public)")
        }
    }

    /// Force a final commit, hand it to the owner, release the shared mic.
    /// No-op when not dictating, so every dismissal path can call it.
    func stop() async {
        guard let voice, micState == .dictating else { return }

        capTask?.cancel()
        capTask = nil
        removeInterruptionObserver()

        voice.audioService.stopStreamingRecording()
        try? await voice.sttService?.commitAndClose()
        await drainFinalCommit()

        eventListenerTask?.cancel()
        eventListenerTask = nil
        await voice.sttService?.disconnect()

        partialTranscript = ""
        micState = .idle
        Logger.stt.info("🎙️ Text dictation stopped")
    }

    // MARK: - Internal

    private func startEventListener(_ sttService: ElevenLabsSTTServiceProtocol) {
        eventListenerTask?.cancel()
        // Fresh stream per dictation: the service is shared with the quiz, and
        // cancelling a listener finishes its stream for good.
        let stream = sttService.makeEventStream()
        eventListenerTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case let .partialTranscript(text):
                    self.partialTranscript = text
                case let .committedTranscript(text):
                    self.onSegment(text)
                    self.partialTranscript = ""
                case .connected:
                    break
                case .disconnected:
                    // Socket drop: stop the mic rather than stay stuck `.dictating`.
                    self.abort()
                    return
                }
            }
        }
    }

    /// Bounded wait so the forced-commit words land before the listener goes.
    private func drainFinalCommit() async {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if partialTranscript.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func startCapTimer() {
        capTask?.cancel()
        capTask = Task { [weak self] in
            guard let self else { return }
            let seconds = self.maxDictationSeconds
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self.micState == .dictating else { return }
            self.didHitDictationCap = true
            await self.stop()
        }
    }

    /// Tear down without the graceful drain — socket drop or interruption.
    private func abort() {
        guard micState == .dictating else { return }
        capTask?.cancel()
        capTask = nil
        eventListenerTask?.cancel()
        eventListenerTask = nil
        removeInterruptionObserver()
        voice?.audioService.stopStreamingRecording()
        partialTranscript = ""
        micState = .idle
        Logger.stt.warning("⚠️ Text dictation torn down (socket drop / interruption)")
    }

    /// The shared `AudioService` reports interruptions only to `QuizViewModel`;
    /// without our own observer `micState` would be stranded `.dictating`.
    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard typeValue == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                self?.abort()
            }
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }
}
