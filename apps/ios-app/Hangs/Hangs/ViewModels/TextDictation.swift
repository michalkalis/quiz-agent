//
//  TextDictation.swift
//  Hangs
//
//  The one "dictate into a text field" engine: the feedback sheet, the rating
//  panel and the custom-pack prompt all own one.
//
//  #208.8 (founder 2026-10-16: all speech-to-text goes through OpenAI on the
//  server): record, then transcribe. The mic records 16 kHz mono PCM on the
//  SHARED `AudioService` (never a fresh one: a second AVAudioEngine is the
//  #64/#77 crash class); when the user stops (or the cap or an interruption
//  does), the clip goes to `POST /voice/dictation` once and its text is handed
//  to `onSegment`, so the owner appends it to its own editable text.
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
    /// The recording is with the server, being turned into text.
    @Published private(set) var isTranscribing = false
    /// Set when the cap auto-stops a dictation, so the UI can say why.
    @Published private(set) var didHitDictationCap = false
    /// The last recording brought no text back (offline, server error, or
    /// nothing intelligible), so the UI can say so instead of staying silent.
    @Published private(set) var didFailTranscription = false

    /// Hard cap for one dictation. Injectable so tests drive the auto-stop.
    var maxDictationSeconds: TimeInterval = Config.feedbackDictationCapSecs

    private let voice: FeedbackVoiceServices?
    private let networkService: NetworkServiceProtocol?
    /// The PCM of the dictation in progress. The tap runs on an audio thread,
    /// so it appends through a lock (serial tap: never contended).
    private let pcm = OSAllocatedUnfairLock<Data>(initialState: Data())
    private var languageCode = "en"
    private var onSegment: (String) -> Void = { _ in }
    private var onRecorded: (Data) -> Void = { _ in }
    private var capTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    /// Nil `voice` (previews, snapshots, tests without audio) means no mic UI.
    init(voice: FeedbackVoiceServices?, networkService: NetworkServiceProtocol?) {
        self.voice = voice
        self.networkService = networkService
    }

    var isAvailable: Bool { voice != nil && networkService != nil }
    var isDictating: Bool { micState == .dictating }
    /// The quiz holds the shared mic — dictation stays blocked (single engine).
    var isBlockedByQuizRecording: Bool { voice?.isQuizRecording() ?? false }
    var micButtonDisabled: Bool { isBlockedByQuizRecording || micState == .denied || isTranscribing }

    /// Join a committed segment onto existing text with a single space.
    static func appending(_ segment: String, to text: String) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return text }
        if text.isEmpty { return segment }
        if text.last == " " || text.last == "\n" { return text + segment }
        return text + " " + segment
    }

    func toggle(
        languageCode: String,
        onSegment: @escaping (String) -> Void,
        onRecorded: @escaping (Data) -> Void = { _ in }
    ) async {
        switch micState {
        case .dictating:
            await stop()
        case .idle, .denied:
            await start(languageCode: languageCode, onSegment: onSegment, onRecorded: onRecorded)
        }
    }

    /// Open the mic and record in `languageCode`. `onSegment` gets the text,
    /// `onRecorded` the raw 16 kHz PCM of every finished recording (the
    /// feedback report attaches it as the transcript's fallback).
    func start(
        languageCode: String,
        onSegment: @escaping (String) -> Void,
        onRecorded: @escaping (Data) -> Void = { _ in }
    ) async {
        guard let voice, networkService != nil else { return }
        // Single-engine guard: never open the mic while the quiz holds it.
        guard !voice.isQuizRecording(), micState != .dictating, !isTranscribing else { return }

        // Typing always works, so a denial only flips the mic to `.denied`.
        guard await voice.audioService.requestMicrophonePermission() else {
            micState = .denied
            Logger.audio.info("🎙️ Text dictation blocked — mic permission denied")
            return
        }

        self.languageCode = languageCode
        self.onSegment = onSegment
        self.onRecorded = onRecorded
        didHitDictationCap = false
        didFailTranscription = false
        pcm.withLock { $0 = Data() }

        do {
            await voice.audioService.prepareForRecording()

            // Re-check after the await: a quiz timer under the sheet could have
            // taken the shared mic in that window.
            guard !voice.isQuizRecording() else {
                micState = .idle
                Logger.stt.info("🎙️ Text dictation aborted — quiz took the mic during setup")
                return
            }

            let pcm = pcm
            try await voice.audioService.startStreamingRecording { chunk in
                pcm.withLock { $0.append(chunk) }
            }

            micState = .dictating
            startCapTimer()
            registerInterruptionObserver()
            Logger.stt.info("🎙️ Text dictation started")
        } catch {
            voice.audioService.stopStreamingRecording()
            micState = .idle
            Logger.stt.warning("⚠️ Text dictation failed to start: \(error, privacy: .public)")
        }
    }

    /// Release the mic, transcribe what was recorded and hand the text to the
    /// owner. Returns once that text has landed, so a Send / Save right after
    /// includes it. Safe to call from every dismissal path (no-op when idle).
    func stop() async {
        if let voice, micState == .dictating {
            capTask?.cancel()
            capTask = nil
            removeInterruptionObserver()
            voice.audioService.stopStreamingRecording()
            micState = .idle
            Logger.stt.info("🎙️ Text dictation stopped")

            let recorded = pcm.withLock { data in
                defer { data = Data() }
                return data
            }
            if !recorded.isEmpty {
                onRecorded(recorded)
                let wav = WavEncoder.wrapPCM16(recorded)
                transcriptionTask = Task { [weak self] in await self?.transcribe(wav) }
            }
        }
        await transcriptionTask?.value
    }

    // MARK: - Internal

    private func transcribe(_ wav: Data) async {
        guard let networkService else { return }
        isTranscribing = true
        defer {
            isTranscribing = false
            transcriptionTask = nil
        }
        do {
            let text = try await networkService.transcribeDictation(audioWAV: wav, language: languageCode)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                didFailTranscription = true
                Logger.stt.info("🎙️ Dictation transcribed to nothing")
            } else {
                onSegment(trimmed)
            }
        } catch {
            didFailTranscription = true
            Logger.stt.warning("⚠️ Dictation transcription failed: \(error, privacy: .public)")
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
            // Detach first: stop() cancels capTask, the task running this.
            self.capTask = nil
            await self.stop()
        }
    }

    /// The shared `AudioService` reports interruptions only to `QuizViewModel`;
    /// without our own observer `micState` would be stranded `.dictating`.
    /// What was recorded up to the interruption is still transcribed.
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
                await self?.stop()
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
