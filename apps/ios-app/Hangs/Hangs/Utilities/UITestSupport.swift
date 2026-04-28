//
//  UITestSupport.swift
//  Hangs
//
//  Active only in DEBUG builds when launched with `--ui-test`.
//  Wires deterministic mock services and exposes a registry so the
//  hangs-test:// URL scheme handler can drive STT events programmatically
//  without real audio input.
//

#if DEBUG

import Foundation
import os

@MainActor
enum UITestSupport {
    /// True iff the app was launched with `--ui-test` in `CommandLine.arguments`.
    static var isUITesting: Bool {
        CommandLine.arguments.contains("--ui-test")
    }

    /// Live mock STT registered by `makeMockServices()`. The URL-scheme handler
    /// uses this to inject events into the running ViewModel.
    private static var mockSTT: MockElevenLabsSTTService?

    /// Build a fully-mocked service graph pre-populated with default fixtures
    /// so a quiz can be started end-to-end without a backend or audio hardware.
    static func makeMockServices() -> (
        network: NetworkServiceProtocol,
        audio: AudioServiceProtocol,
        persistence: PersistenceStoreProtocol,
        silence: SilenceDetectionServiceProtocol?,
        stt: ElevenLabsSTTServiceProtocol?
    ) {
        let network = MockNetworkService()
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = QuizResponse.previewStartQuiz

        let audio = MockAudioService()
        let persistence = MockPersistenceStore()

        let stt = MockElevenLabsSTTService()
        mockSTT = stt

        Logger.quiz.info("🧪 UITestSupport: mock services wired")
        return (network, audio, persistence, nil, stt)
    }

    /// Inject an arbitrary STT event into the live mock STT.
    /// Returns false if no mock has been registered (e.g., not in UI test mode).
    @discardableResult
    static func injectSTTEvent(_ event: STTEvent) async -> Bool {
        guard let stt = mockSTT else {
            Logger.quiz.error("🧪 UITestSupport: injectSTTEvent called but no mock STT is registered")
            return false
        }
        await stt.injectEvent(event)
        return true
    }

    /// Route a `hangs-test://` URL to the appropriate mock action.
    ///
    /// Supported URLs:
    /// - `hangs-test://stt/partial?text=foo`   → `STTEvent.partialTranscript("foo")`
    /// - `hangs-test://stt/committed?text=foo` → `STTEvent.committedTranscript("foo")`
    /// - `hangs-test://stt/connected`          → `STTEvent.connected`
    /// - `hangs-test://stt/disconnect?msg=x`   → `STTEvent.disconnected(error)`
    static func handleTestURL(_ url: URL) async {
        guard url.scheme == "hangs-test" else { return }

        let host = url.host ?? ""
        let path = url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let text = queryItems.first(where: { $0.name == "text" })?.value ?? ""

        Logger.quiz.info("🧪 UITestSupport: handling URL host=\(host, privacy: .public) path=\(path, privacy: .public)")

        switch (host, path) {
        case ("stt", "/partial"):
            await injectSTTEvent(.partialTranscript(text))
        case ("stt", "/committed"):
            await injectSTTEvent(.committedTranscript(text))
        case ("stt", "/connected"):
            await injectSTTEvent(.connected)
        case ("stt", "/disconnect"):
            let msg = queryItems.first(where: { $0.name == "msg" })?.value
            let err: Error? = msg.map { ElevenLabsSTTError.serverError($0) }
            await injectSTTEvent(.disconnected(err))
        default:
            Logger.quiz.error("🧪 UITestSupport: unrecognized URL \(url.absoluteString, privacy: .public)")
        }
    }
}

#endif
