//
//  FeedbackViewModel.swift
//  Hangs
//
//  Drives the in-app beta feedback sheet (#109, phase 2 — typing only, no voice
//  yet). Builds the metadata JSON, gathers the recent-log tail, and POSTs the
//  multipart feedback report to our own backend inbox.
//

import Combine
import Foundation
import os
import Sentry
import UIKit

/// Snapshot of the app state at the moment feedback was triggered. Captured on
/// the MainActor by the presenter (shake handler / Settings row) so the report
/// reflects the screen the user was actually on, not a later state.
struct FeedbackContext: Sendable {
    var quizState: String
    var sessionId: String?
    var quizLanguage: String
    var audioMode: String

    /// Neutral default for entry points with no live quiz (e.g. Settings).
    static let none = FeedbackContext(
        quizState: "idle",
        sessionId: nil,
        quizLanguage: "en",
        audioMode: AudioMode.default.id
    )
}

@MainActor
extension FeedbackContext {
    /// Build the context from the live quiz view model.
    static func capture(from viewModel: QuizViewModel) -> FeedbackContext {
        FeedbackContext(
            quizState: viewModel.quizState.label,
            sessionId: viewModel.currentSession?.id,
            quizLanguage: viewModel.settings.language,
            audioMode: viewModel.selectedAudioMode.id
        )
    }
}

/// The shared voice-dictation dependencies wired into a feedback sheet (#109
/// phase 3). Bundled optionally so the typing-only path (previews, unit tests
/// that don't exercise voice) constructs a `FeedbackViewModel` without them and
/// the mic UI is simply hidden. **The `audioService` and `sttService` MUST be
/// the same shared instances the quiz answers use** — never fresh ones — or a
/// second `AVAudioEngine` gets created (the #64/#77 two-engine crash class).
@MainActor
struct FeedbackVoiceServices {
    let audioService: AudioServiceProtocol
    let sttService: ElevenLabsSTTServiceProtocol?
    /// Live check: is the quiz itself actively holding the mic (recording or
    /// streaming STT)? Dictation is blocked while true — the single shared engine
    /// can't serve both at once.
    let isQuizRecording: @MainActor () -> Bool
    /// Language code for the STT session (mirrors the quiz's current language).
    let languageCode: String
}

@MainActor
extension AppState {
    /// Build the shared-instance voice dependencies for a feedback sheet (#109).
    /// Passes the app-wide `audioService`/`sttService` through — the SAME objects
    /// the quiz uses — so dictation never spins up a second audio engine.
    func makeFeedbackVoice(for viewModel: QuizViewModel) -> FeedbackVoiceServices {
        FeedbackVoiceServices(
            audioService: audioService,
            sttService: sttService,
            isQuizRecording: { [weak viewModel] in
                guard let viewModel else { return false }
                return viewModel.quizState == .recording || viewModel.isStreamingSTT
            },
            languageCode: viewModel.currentSession?.language ?? viewModel.settings.language
        )
    }
}

/// Identifiable holder so a freshly-built `FeedbackViewModel` can drive a
/// `.sheet(item:)` presentation — the presenter builds one per trigger (shake /
/// Settings row) and stores it in `@State`, keeping the VM's identity stable
/// across body re-evaluations so typed text survives.
struct FeedbackPresentation: Identifiable {
    let id = UUID()
    let viewModel: FeedbackViewModel
}

@MainActor
final class FeedbackViewModel: ObservableObject {
    enum SendState: Equatable {
        case idle
        case sending
        case success
        case failed(String)
    }

    /// Live-transcript state of the mic (#109 phase 3).
    enum MicState: Equatable {
        case idle
        case dictating
        case denied
    }

    @Published var message: String = ""
    @Published var screenshot: UIImage?
    @Published private(set) var sendState: SendState = .idle
    @Published private(set) var micState: MicState = .idle
    /// The in-flight (uncommitted) transcript, shown live while the user speaks.
    /// Committed segments are appended to `message` and this clears.
    @Published private(set) var partialTranscript: String = ""
    /// Set when the 120 s hard cap auto-stops a dictation, so the UI can hint why.
    @Published private(set) var didHitDictationCap = false

    private let networkService: NetworkServiceProtocol
    private let context: FeedbackContext
    private let logsProvider: @Sendable () async -> String?
    private let voice: FeedbackVoiceServices?

    /// Accumulates the same 16 kHz mono PCM chunks streamed to ElevenLabs so the
    /// dictation can be attached as a WAV fallback. `OSAllocatedUnfairLock<Data>`
    /// is Sendable, so the `@Sendable` audio-thread tap closure can append without
    /// `nonisolated(unsafe)`; the tap is serial, so the lock is always uncontended.
    private let pcmAccumulator = OSAllocatedUnfairLock<Data>(initialState: Data())
    /// The finished WAV, built when a dictation stops; attached on send.
    private var dictatedAudioWAV: Data?

    private var eventListenerTask: Task<Void, Never>?
    private var capTask: Task<Void, Never>?

    /// Hard cap for a single dictation. Injectable so tests can drive the auto-stop
    /// without waiting the production 120 s.
    var maxDictationSeconds: TimeInterval = Config.feedbackDictationCapSecs

    init(
        networkService: NetworkServiceProtocol,
        context: FeedbackContext,
        screenshot: UIImage?,
        voice: FeedbackVoiceServices? = nil,
        logsProvider: @escaping @Sendable () async -> String? = { await LogStore.shared.exportText() }
    ) {
        self.networkService = networkService
        self.context = context
        self.screenshot = screenshot
        self.voice = voice
        self.logsProvider = logsProvider
    }

    /// True while a send is in flight — the UI disables Send and the editor.
    var isSending: Bool { sendState == .sending }

    /// Send is enabled once there's non-whitespace text and no send is running.
    var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// Human-readable error from the last failed send, for inline display.
    var errorMessage: String? {
        if case let .failed(reason) = sendState { return reason }
        return nil
    }

    /// Whether the sheet offers voice dictation at all (false in previews / typing
    /// -only tests where no shared audio services were injected).
    var voiceAvailable: Bool { voice != nil }

    var isDictating: Bool { micState == .dictating }

    /// The quiz is actively holding the shared mic, so dictation must stay blocked
    /// (single-engine rule). Shake-to-report itself is unaffected — only the mic
    /// button is disabled.
    var isBlockedByQuizRecording: Bool { voice?.isQuizRecording() ?? false }

    /// The mic button is inert while the quiz records, while a send is in flight,
    /// or when microphone access was denied.
    var micButtonDisabled: Bool {
        isBlockedByQuizRecording || isSending || micState == .denied
    }

    /// Remove the attached screenshot (user tapped the thumbnail's remove button).
    func removeScreenshot() {
        screenshot = nil
    }

    /// The metadata dictionary sent alongside the report. Exposed for the "what
    /// gets sent" caption and for unit tests. Device/app fields are read here;
    /// screen-state fields come from the captured `context`.
    func buildMetadata() -> [String: String] {
        var metadata: [String: String] = [
            "app_version": Self.appVersion,
            "build": Self.buildNumber,
            "ios_version": UIDevice.current.systemVersion,
            "device_model": Self.deviceModel,
            "environment": Config.environmentName,
            "locale": Locale.current.identifier,
            "quiz_language": context.quizLanguage,
            "audio_mode": context.audioMode,
            "quiz_state": context.quizState,
        ]
        if let sessionId = context.sessionId {
            metadata["session_id"] = sessionId
        }
        return metadata
    }

    /// Submit the feedback report: message + metadata + screenshot + audio + log tail.
    func send() async {
        // A tap on Send while still dictating finalizes the recording first, so the
        // last spoken segment and the WAV are captured before the POST.
        if isDictating { await stopDictation() }

        guard canSend else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        sendState = .sending

        let metadata = buildMetadata()
        let metadataJSON = Self.encodeJSON(metadata)
        let screenshotPNG = screenshot?.pngData()
        let logs = await logsProvider()

        do {
            try await networkService.submitFeedback(
                message: trimmed,
                metadataJSON: metadataJSON,
                appVersion: "\(Self.appVersion) (\(Self.buildNumber))",
                screenshotPNG: screenshotPNG,
                audioWAV: dictatedAudioWAV,
                logsText: logs
            )
            addSentBreadcrumb()
            sendState = .success
        } catch {
            sendState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Voice dictation (#109 phase 3)

    /// Toggle dictation: start if idle/denied-retry, stop if recording.
    func toggleDictation() async {
        switch micState {
        case .dictating:
            await stopDictation()
        case .idle, .denied:
            await startDictation()
        }
    }

    /// Begin streaming dictation on the SHARED audio + STT services. Mirrors the
    /// quiz answer flow's token→connect→stream→commit pattern; the PCM chunks are
    /// teed into `pcmAccumulator` for the WAV attachment while they stream.
    func startDictation() async {
        guard let voice, let sttService = voice.sttService else { return }
        // Single-engine guard (#64/#77): never open the mic while the quiz holds it.
        guard !voice.isQuizRecording() else { return }
        guard micState != .dictating else { return }

        // Permission: typing always works, so a denial just flips the mic to its
        // denied state rather than failing the whole sheet.
        let granted = await voice.audioService.requestMicrophonePermission()
        guard granted else {
            micState = .denied
            Logger.audio.info("🎙️ Feedback dictation blocked — mic permission denied")
            return
        }

        // Fresh recording: reset the PCM tee and any prior partial.
        pcmAccumulator.withLock { $0 = Data() }
        partialTranscript = ""
        didHitDictationCap = false

        do {
            let token = try await networkService.fetchElevenLabsToken()
            try await sttService.connect(token: token, languageCode: voice.languageCode)
            startEventListener(sttService)

            await voice.audioService.prepareForRecording()
            let accumulator = pcmAccumulator
            let stt = sttService
            try await voice.audioService.startStreamingRecording { pcmData in
                // Tee: keep the raw PCM for the WAV, and forward it to ElevenLabs.
                accumulator.withLock { $0.append(pcmData) }
                Task { try? await stt.sendAudioChunk(pcmData) }
            }

            micState = .dictating
            startCapTimer()
            Logger.stt.info("🎙️ Feedback dictation started")
        } catch {
            // Teardown on any setup failure; typing stays available.
            eventListenerTask?.cancel()
            eventListenerTask = nil
            voice.audioService.stopStreamingRecording()
            await sttService.disconnect()
            partialTranscript = ""
            micState = .idle
            Logger.stt.warning("⚠️ Feedback dictation failed to start: \(error, privacy: .public)")
        }
    }

    /// Stop dictation: force a final commit, drain it into `message`, tear down the
    /// stream, and freeze the teed PCM into a WAV attachment.
    func stopDictation() async {
        guard let voice, micState == .dictating else { return }

        capTask?.cancel()
        capTask = nil

        // Stop the mic first so no more PCM is teed, then force-commit any pending
        // words. The listener appends the final committed segment before we cut it.
        voice.audioService.stopStreamingRecording()
        try? await voice.sttService?.commitAndClose()
        // Let the listener drain the forced commit before tearing it down.
        await drainFinalCommit()

        eventListenerTask?.cancel()
        eventListenerTask = nil
        await voice.sttService?.disconnect()

        partialTranscript = ""
        micState = .idle
        buildWavAttachment()
        Logger.stt.info("🎙️ Feedback dictation stopped")
    }

    /// Listen for STT events during a dictation. Unlike the quiz flow, a committed
    /// transcript does NOT end the session — each VAD-committed segment appends to
    /// the editable `message` and dictation continues until the user stops.
    private func startEventListener(_ sttService: ElevenLabsSTTServiceProtocol) {
        eventListenerTask?.cancel()
        eventListenerTask = Task { [weak self] in
            for await event in sttService.events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case let .partialTranscript(text):
                    self.partialTranscript = text
                case let .committedTranscript(text):
                    self.appendCommitted(text)
                    self.partialTranscript = ""
                case .connected:
                    break
                case .disconnected:
                    self.partialTranscript = ""
                    return
                }
            }
        }
    }

    /// Append a committed segment to the editable note, inserting a single space so
    /// segments don't run together. Empty commits (VAD dead-air) are ignored.
    private func appendCommitted(_ text: String) {
        let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        if message.isEmpty {
            message = segment
        } else if message.last == " " || message.last == "\n" {
            message += segment
        } else {
            message += " " + segment
        }
    }

    /// Bounded wait for the forced-commit segment to arrive after `commitAndClose`,
    /// so the last spoken words land in `message` before the listener is cancelled.
    /// Returns promptly once a committed segment clears the partial, or after a
    /// short ceiling if the socket went silent.
    private func drainFinalCommit() async {
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if partialTranscript.isEmpty { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
    }

    private func startCapTimer() {
        capTask?.cancel()
        capTask = Task { [weak self] in
            guard let self else { return }
            let seconds = self.maxDictationSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, self.micState == .dictating else { return }
            self.didHitDictationCap = true
            await self.stopDictation()
            Logger.stt.info("🎙️ Feedback dictation hit the \(Int(seconds), privacy: .public)s cap")
        }
    }

    private func buildWavAttachment() {
        let pcm = pcmAccumulator.withLock { $0 }
        guard !pcm.isEmpty else { return }
        dictatedAudioWAV = WavEncoder.wrapPCM16(pcm)
    }

    // MARK: - Helpers

    /// Sentry breadcrumb so a later crash can be correlated with a feedback
    /// report the same tester filed (#109). No-op when the SDK is off (simulator).
    private func addSentBreadcrumb() {
        let crumb = Breadcrumb(level: .info, category: "feedback.sent")
        crumb.message = "feedback.sent"
        crumb.data = ["quiz_state": context.quizState, "has_screenshot": screenshot != nil]
        SentryBreadcrumb.add(crumb)
    }

    private static func encodeJSON(_ dict: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }

    /// Hardware identifier (e.g. "iPhone16,1"). On the simulator this reads the
    /// host model from the environment; falls back to `uname` on device.
    private static var deviceModel: String {
        if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simModel
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { bytes -> String in
            let data = Data(bytes)
            return String(decoding: data.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }
}
