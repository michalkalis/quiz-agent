//
//  FeedbackViewModel.swift
//  Hangs
//
//  Drives the in-app beta feedback sheet (#109, phase 2 — typing only, no voice
//  yet). Builds the metadata JSON, gathers the recent-log tail, and POSTs the
//  multipart feedback report to our own backend inbox.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import os
import Sentry
import UIKit

/// Snapshot of the app state at the moment feedback was triggered. Captured on
/// the MainActor by the presenter (feedback chip / Settings row) so the report
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
/// the mic UI is simply hidden. **The `audioService` MUST be the same shared
/// instance the quiz answers use** — never a fresh one — or a second
/// `AVAudioEngine` gets created (the #64/#77 two-engine crash class).
@MainActor
struct FeedbackVoiceServices {
    let audioService: AudioServiceProtocol
    /// Live check: is the quiz itself actively holding the mic? Dictation is
    /// blocked while true — the single shared engine can't serve both at once.
    let isQuizRecording: @MainActor () -> Bool
    /// Language hint for the transcription (the quiz's current language).
    let languageCode: String
}

@MainActor
extension AppState {
    /// Build the shared-instance voice dependencies for a feedback sheet (#109).
    /// Passes the app-wide `audioService` through — the SAME object the quiz
    /// uses — so dictation never spins up a second audio engine.
    func makeFeedbackVoice(for viewModel: QuizViewModel) -> FeedbackVoiceServices {
        FeedbackVoiceServices(
            audioService: audioService,
            isQuizRecording: { [weak viewModel] in
                viewModel?.quizState == .recording
            },
            languageCode: viewModel.currentSession?.language ?? viewModel.settings.language
        )
    }

    /// A feedback sheet for the screen the user is on (#109): a snapshot of the
    /// quiz state plus `screenshot`, which defaults to capturing the key window
    /// NOW — before the sheet presents, so the shot shows the reported screen.
    func makeFeedbackPresentation(
        for viewModel: QuizViewModel,
        screenshot: UIImage? = ScreenshotCapture.captureKeyWindow()
    ) -> FeedbackPresentation {
        FeedbackPresentation(
            viewModel: FeedbackViewModel(
                networkService: networkService,
                context: FeedbackContext.capture(from: viewModel),
                screenshot: screenshot,
                voice: makeFeedbackVoice(for: viewModel)
            )
        )
    }
}

/// Identifiable holder so a freshly-built `FeedbackViewModel` can drive a
/// `.sheet(item:)` presentation — the presenter builds one per trigger (feedback
/// chip / Settings row) and stores it in `@State`, keeping the VM's identity stable
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

    typealias MicState = TextDictation.MicState

    @Published var message: String = ""
    @Published var screenshot: UIImage?
    @Published private(set) var sendState: SendState = .idle

    private let networkService: NetworkServiceProtocol
    private let context: FeedbackContext
    private let logsProvider: @Sendable () async -> String?
    private let voice: FeedbackVoiceServices?
    /// The shared dictation engine (#208.8: record, then transcribe on the server).
    let dictation: TextDictation
    private var dictationChanges: AnyCancellable?

    /// The PCM of every dictation on this sheet, so the report attaches the
    /// voice recording as the transcript's fallback. It accumulates across
    /// dictations (a note dictated in several passes attaches ALL of them) and
    /// is reset only after a successful send (#109 review).
    private var dictatedPCM = Data()
    /// The finished WAV, rebuilt after each dictation; attached on send.
    private var dictatedAudioWAV: Data?

    /// Hard cap for a single dictation. Injectable so tests can drive the auto-stop
    /// without waiting the production 120 s.
    var maxDictationSeconds: TimeInterval {
        get { dictation.maxDictationSeconds }
        set { dictation.maxDictationSeconds = newValue }
    }

    init(
        networkService: NetworkServiceProtocol,
        context: FeedbackContext,
        screenshot: UIImage?,
        voice: FeedbackVoiceServices? = nil,
        logsProvider: @escaping @Sendable () async -> String? = {
            // #186 step 1: the quiz flight recorder leads the report — the input
            // trail behind whatever the tester is describing.
            let logs = await LogStore.shared.exportText()
            return QuizFlightRecorder.shared.dump() + "\n\n" + logs
        }
    ) {
        self.networkService = networkService
        self.context = context
        self.screenshot = screenshot
        self.voice = voice
        self.logsProvider = logsProvider
        dictation = TextDictation(voice: voice, networkService: networkService)
        // The views observe this model; the engine's state changes must redraw them.
        dictationChanges = dictation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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

    var micState: MicState { dictation.micState }
    var isDictating: Bool { dictation.isDictating }
    /// The recording is with the server, being turned into text.
    var isTranscribing: Bool { dictation.isTranscribing }
    /// Set when the 120 s hard cap auto-stops a dictation, so the UI can hint why.
    var didHitDictationCap: Bool { dictation.didHitDictationCap }
    var didFailTranscription: Bool { dictation.didFailTranscription }

    /// The quiz is actively holding the shared mic, so dictation must stay blocked
    /// (single-engine rule). Opening the feedback sheet is unaffected — only the mic
    /// button is disabled.
    var isBlockedByQuizRecording: Bool { dictation.isBlockedByQuizRecording }

    /// The mic button is inert while the quiz records, while a send is in flight,
    /// while a recording is being transcribed, or when microphone access was denied.
    var micButtonDisabled: Bool {
        dictation.micButtonDisabled || isSending
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
        // A tap on Send while still dictating (or transcribing) finalizes the
        // recording first, so the last spoken words and the WAV go with the POST.
        await stopDictation()

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
            // Clear the accumulated dictation audio now the report is sent — a
            // fresh dictation on a reused sheet starts from an empty buffer.
            dictatedPCM = Data()
            dictatedAudioWAV = nil
            sendState = .success
        } catch {
            sendState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Voice dictation (#109 phase 3, #208.8 record then transcribe)

    /// Toggle dictation: start if idle/denied-retry, stop if recording.
    func toggleDictation() async {
        switch micState {
        case .dictating:
            await stopDictation()
        case .idle, .denied:
            await startDictation()
        }
    }

    /// Record on the SHARED audio service; the text lands in `message` when the
    /// recording stops, and its PCM joins the WAV attachment.
    func startDictation() async {
        guard let voice else { return }
        await dictation.start(
            languageCode: voice.languageCode,
            onSegment: { [weak self] text in
                guard let self else { return }
                message = TextDictation.appending(text, to: message)
            },
            onRecorded: { [weak self] pcm in
                guard let self else { return }
                dictatedPCM.append(pcm)
                dictatedAudioWAV = WavEncoder.wrapPCM16(dictatedPCM)
            }
        )
    }

    /// Stop dictation and wait for its text to land in `message`.
    func stopDictation() async {
        await dictation.stop()
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
