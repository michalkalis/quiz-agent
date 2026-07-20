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
    import Network
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

        /// Live command sink registered by `AppState.makeQuizViewModel()` when
        /// `--ui-test` is active (issue #111 T3). Routes a transcript straight into
        /// `QuizViewModel.handleCommandTranscript` — the real `handleRecognizedCommand`
        /// → `routeCommand` pipeline — so voice-driven navigation is UI-testable even
        /// though the recognizer itself is `nil` under `--ui-test`.
        private static var commandSink: (@MainActor (String) async -> Void)?

        /// Strong reference to the loopback HTTP listener (kept alive for the app lifetime).
        private static var listener: NWListener?

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

            if CommandLine.arguments.contains("--ui-test-incorrect") {
                network.mockTextInputResponse = QuizResponse.previewAnswerIncorrect
            } else {
                network.mockTextInputResponse = QuizResponse.previewAnswerCorrect
            }

            if CommandLine.arguments.contains("--ui-test-paywall") {
                network.createSessionError = NetworkError.quotaLimitReached(QuotaLimitError(
                    error: "quota_limit_reached",
                    questionsUsed: 5,
                    questionsLimit: 5,
                    resetsAt: "2099-01-01T08:00:00.000Z",
                    upgradeAvailable: true
                ))
            }

            let audio = MockAudioService()
            let persistence = MockPersistenceStore()

            // Disable the 10s auto-confirm timer under UI test. Edit-flow scenarios
            // (RS-06/07/08) drive the confirmation sheet through accessibility-tree
            // taps and field typing; the timer fires before they can land.
            if CommandLine.arguments.contains("--ui-test-mcq") {
                network.mockSession = QuizResponse.previewStartQuizMCQ.session
                network.mockResponse = QuizResponse.previewStartQuizMCQ
            }

            if CommandLine.arguments.contains("--ui-test-long") {
                network.mockSession = QuizResponse.previewStartQuizLong.session
                network.mockResponse = QuizResponse.previewStartQuizLong
            }

            var seededSettings = QuizSettings.default
            seededSettings.autoConfirmEnabled = false
            // Short answer timer so recording auto-starts within ~1s (no mic button in redesigned UI).
            if CommandLine.arguments.contains("--ui-test-mcq") {
                seededSettings.answerTimeLimit = 1
            }
            persistence.savedSettings = seededSettings

            let stt = MockElevenLabsSTTService()
            mockSTT = stt

            Logger.quiz.info("🧪 UITestSupport: mock services wired (autoConfirmEnabled=false)")
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

        /// Register the live command sink. Called by `AppState.makeQuizViewModel()`
        /// once the real `QuizViewModel` exists. A later registration replaces the
        /// former (idempotent).
        static func registerCommandSink(_ sink: @escaping @MainActor (String) async -> Void) {
            commandSink = sink
        }

        /// Route an arbitrary transcript to the registered command sink.
        /// Returns false if no sink has been registered (e.g., not in UI test mode).
        @discardableResult
        static func handleCommand(_ text: String) async -> Bool {
            guard let commandSink else {
                Logger.quiz.error("🧪 UITestSupport: handleCommand called but no command sink is registered")
                return false
            }
            await commandSink(text)
            return true
        }

        /// Route a `hangs-test://` URL to the appropriate mock action.
        ///
        /// Supported URLs:
        /// - `hangs-test://stt/partial?text=foo`   → `STTEvent.partialTranscript("foo")`
        /// - `hangs-test://stt/committed?text=foo` → `STTEvent.committedTranscript("foo")`
        /// - `hangs-test://stt/connected`          → `STTEvent.connected`
        /// - `hangs-test://stt/disconnect?msg=x`   → `STTEvent.disconnected(error)`
        /// - `hangs-test://command/send?text=start` → registered command sink("start"),
        ///   driving the real `handleCommandTranscript` → `routeCommand` pipeline
        ///   (issue #111 T3 — voice-command test seam).
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
            case ("command", "/send"):
                await handleCommand(text)
            default:
                Logger.quiz.error("🧪 UITestSupport: unrecognized URL \(url.absoluteString, privacy: .public)")
            }
        }

        /// Bind a tiny HTTP server on `127.0.0.1:9999` that translates incoming
        /// requests into the same mock-STT events as the `hangs-test://` URL
        /// scheme. Workaround for the iOS 26.3 simulator LaunchServices bug
        /// (`kLSApplicationNotFoundErr`) which drops custom URL scheme delivery.
        /// Idempotent — calling twice is a no-op.
        static func startTestListener() {
            guard listener == nil else { return }

            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 9999)!
            )
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = endpoint
            params.allowLocalEndpointReuse = true

            do {
                let newListener = try NWListener(using: params)
                newListener.newConnectionHandler = { connection in
                    Self.handleConnection(connection)
                }
                newListener.start(queue: .global(qos: .userInitiated))
                listener = newListener
                Logger.quiz.info("🧪 UITestSupport: HTTP listener bound to 127.0.0.1:9999")
            } catch {
                Logger.quiz.error("🧪 UITestSupport: listener bind failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        /// Read one HTTP request, log + dispatch it via `handleTestURL`, write a
        /// minimal 200 response, then close the connection. Runs on the listener's
        /// dispatch queue; hops to MainActor for the actual mock injection.
        private nonisolated static func handleConnection(_ connection: NWConnection) {
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                defer {
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    let bytes = Data(response.utf8)
                    connection.send(content: bytes, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }

                guard
                    let data,
                    let requestText = String(data: data, encoding: .utf8),
                    let firstLine = requestText.split(separator: "\r\n", maxSplits: 1).first
                else { return }

                let parts = firstLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else { return }
                let method = String(parts[0])
                let pathAndQuery = String(parts[1])
                guard pathAndQuery.hasPrefix("/") else { return }

                // pathAndQuery is e.g. "/stt/committed?text=Paris" — drop the
                // leading "/" and prepend "hangs-test://" to reuse handleTestURL.
                let urlString = "hangs-test://" + pathAndQuery.dropFirst()
                guard let url = URL(string: urlString) else { return }

                Logger.quiz.info("🧪 HTTP: \(method, privacy: .public) \(pathAndQuery, privacy: .public)")

                Task { @MainActor in
                    await UITestSupport.handleTestURL(url)
                }
            }
        }
    }

#endif
