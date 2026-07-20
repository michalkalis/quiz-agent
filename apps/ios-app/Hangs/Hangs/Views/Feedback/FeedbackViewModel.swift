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

    @Published var message: String = ""
    @Published var screenshot: UIImage?
    @Published private(set) var sendState: SendState = .idle

    private let networkService: NetworkServiceProtocol
    private let context: FeedbackContext
    private let logsProvider: @Sendable () async -> String?

    init(
        networkService: NetworkServiceProtocol,
        context: FeedbackContext,
        screenshot: UIImage?,
        logsProvider: @escaping @Sendable () async -> String? = { await LogStore.shared.exportText() }
    ) {
        self.networkService = networkService
        self.context = context
        self.screenshot = screenshot
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

    /// Submit the feedback report: message + metadata + screenshot + log tail.
    func send() async {
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
                logsText: logs
            )
            addSentBreadcrumb()
            sendState = .success
        } catch {
            sendState = .failed(error.localizedDescription)
        }
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
