//
//  UITestSupport.swift
//  Hangs
//
//  Active only in DEBUG builds when launched with `--ui-test`.
//  Wires deterministic mock services and exposes a registry so the
//  hangs-test:// URL scheme handler can inject a spoken answer, a voice
//  command or an audio interruption without real audio input.
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

        /// The live mocks registered by `makeMockServices()`. A spoken answer is
        /// injected through them (#208.8): the "mic" delivers a short clip and
        /// the end of speech, and the "server" hears the injected transcript.
        private static var mockNetwork: MockNetworkService?
        private static var mockRooms: MockRoomService?
        /// #212: where a test's join link lands, as if the player opened it.
        static weak var roomInvites: RoomInviteInbox?
        /// #213.8: the host's game-together rules, emptied once per launch so
        /// every RS run starts from the defaults (a test's change never leaks).
        static let roomSettingsDefaults: UserDefaults = {
            let name = "ui-test-room-settings"
            let defaults = UserDefaults(suiteName: name) ?? .standard
            defaults.removePersistentDomain(forName: name)
            return defaults
        }()

        private static var mockSilence: MockSilenceDetectionService?
        /// `/recording/interrupt` drives a phone call through it, along the
        /// same routing the real `AudioService` uses.
        private static var mockAudio: MockAudioService?

        /// Live command sink registered by `AppState.sharedQuizViewModel()` when
        /// `--ui-test` is active (issue #111 T3). Routes a transcript straight into
        /// `VoiceCommandCoordinator.handleCommandTranscript` — the real `handleRecognizedCommand`
        /// → `routeCommand` pipeline — so voice-driven navigation is UI-testable even
        /// though the recognizer under `--ui-test` is an `.unavailable` mock
        /// that never yields transcripts.
        private static var commandSink: (@MainActor (String) async -> Void)?

        /// Strong reference to the loopback HTTP listener (kept alive for the app lifetime).
        private static var listener: NWListener?

        /// Build a fully-mocked service graph pre-populated with default fixtures
        /// so a quiz can be started end-to-end without a backend or audio hardware.
        static func makeMockServices() -> (
            network: NetworkServiceProtocol,
            audio: AudioServiceProtocol,
            persistence: PersistenceStoreProtocol,
            silence: SilenceDetectionServiceProtocol,
            rooms: RoomServiceProtocol
        ) {
            let network = MockNetworkService()
            network.mockSession = QuizResponse.previewStartQuiz.session
            network.mockResponse = QuizResponse.previewStartQuiz
            network.tracksSessionScore = true

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

            // #123 Track B: seed the Home entitlement card's key visuals for the
            // screenshot-verify sweep. /usage is mocked, so stub the payload (or
            // stall it) instead of hitting a backend. Combine with `--ui-test`.
            if CommandLine.arguments.contains("--ui-test-plan-free-credits") {
                // The money shot: 12 monthly free + 100 pack credits → "112"
                // combined total, two-tone blue+purple track.
                network.stubbedUsage = UsageInfo(
                    userId: "mock-subject", isPremium: false, questionsUsed: 18,
                    questionsLimit: 30, remaining: 12,
                    resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400)),
                    subscriptionStatus: "none", creditBalance: 100
                )
            }
            if CommandLine.arguments.contains("--ui-test-plan-subscriber") {
                network.stubbedUsage = UsageInfo(
                    userId: "mock-subject", isPremium: false, questionsUsed: 130,
                    questionsLimit: 1000, remaining: 870,
                    resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(30 * 86400)),
                    subscriptionStatus: "active", creditBalance: 0
                )
            }
            if CommandLine.arguments.contains("--ui-test-plan-loading") {
                // Never-resolving /usage → the card holds its loading placeholder
                // so the loading→loaded frame-stability can be verified.
                network.getUsageGate = { try? await Task.sleep(for: .seconds(600)) }
            }

            // #205: the daily challenge flags (DailyChallengeFixtures).
            DailyChallengeFixtures.configure(network)

            let audio = MockAudioService()
            let persistence = MockPersistenceStore()

            // #125: these were two independent `if` blocks where `--ui-test-long`
            // overwrote `--ui-test-mcq`, so the shape that actually broke in the
            // field — a long stem competing with four fixed-height option cards —
            // could not be seeded at all. Compose them instead.
            let wantsMCQ = CommandLine.arguments.contains("--ui-test-mcq")
            let wantsLong = CommandLine.arguments.contains("--ui-test-long")
            // #179 finding 10: the other MCQ overflow — an ordinary stem with
            // four multi-line OPTIONS. Its own flag, because it is the options
            // that must be long here, not the stem.
            if CommandLine.arguments.contains("--ui-test-mcq-long-options") {
                network.mockSession = QuizResponse.previewStartQuizMCQLongOptions.session
                network.mockResponse = QuizResponse.previewStartQuizMCQLongOptions
            } else {
                switch (wantsMCQ, wantsLong) {
                case (true, true):
                    network.mockSession = QuizResponse.previewStartQuizMCQLong.session
                    network.mockResponse = QuizResponse.previewStartQuizMCQLong
                case (true, false):
                    network.mockSession = QuizResponse.previewStartQuizMCQ.session
                    network.mockResponse = QuizResponse.previewStartQuizMCQ
                case (false, true):
                    network.mockSession = QuizResponse.previewStartQuizLong.session
                    network.mockResponse = QuizResponse.previewStartQuizLong
                case (false, false):
                    break
                }
            }

            var seededSettings = QuizSettings.default
            // Disable the 10s auto-confirm timer under UI test. Edit-flow scenarios
            // (RS-06/07/08) drive the confirmation sheet through accessibility-tree
            // taps and field typing; the timer fires before they can land.
            seededSettings.autoConfirmEnabled = false
            // #200: auto-record is always on, so the think window is what opens
            // the mic under UI test (recording is then driven by an injected
            // spoken answer). Voice scenarios keep the 30 s the retired answer timer
            // gave them — they tap Record well inside it.
            // MCQ: a short window so recording auto-starts within ~1s (no mic
            // button in redesigned UI). #125: the long-stem MCQ fixture needs an
            // observable PRE-reveal window (options + listening pill still hidden
            // while the countdown runs), so that combination gets a few seconds.
            seededSettings.thinkingTime = wantsMCQ ? (wantsLong ? 5 : 1) : 30
            // #190: store-screenshot mode — listing-quality content in the quiz
            // language, calm frames (no ticking pills), populated Home.
            if StoreScreenshotFixtures.isActive {
                let language = StoreScreenshotFixtures.quizLanguage
                let content = StoreScreenshotFixtures.content(forQuizLanguage: language)
                let open = StoreScreenshotFixtures.openQuestion(content, language: language)
                let mcq = StoreScreenshotFixtures.mcqQuestion(content, language: language)
                let first = wantsMCQ ? mcq : open
                let start = StoreScreenshotFixtures.quizResponse(question: first)
                network.mockSession = start.session
                network.mockResponse = start
                network.mockTextInputResponse = StoreScreenshotFixtures.quizResponse(
                    question: mcq,
                    evaluation: StoreScreenshotFixtures.correctEvaluation(content, questionId: open.id),
                    answered: 1, correct: 1
                )
                network.stubbedUsage = StoreScreenshotFixtures.usage
                seededSettings.language = language
                // No ticking pills: thinking / auto-advance countdowns never
                // start — the scenes are seeded statically in AppState.
            }
            persistence.savedSettings = seededSettings
            // #200 RS-24: the Home pack (the mock's delivered one) already played
            // through on this phone, so its play control asks before starting over.
            if CommandLine.arguments.contains("--ui-test-pack-played-through"),
               let packId = OrderSnapshot.mockDelivered.packId
            {
                for index in 0 ..< OrderSnapshot.mockDelivered.targetCount {
                    persistence.markPackQuestionPlayed("played_\(index)", packId: packId)
                }
            }

            // Silence mock seeded `.unavailable`: keeps the command-listener hint
            // (and, before #179 D1, the ListenBar itself) hidden exactly as the
            // old `nil` service did — a default `.ready` mock would arm the
            // listener window across every `--ui-test` scenario.
            //
            // `--ui-test-commands-ready` opts a scenario INTO the armed listener.
            // Since #179 D1 the bar is always on screen and only its command
            // CHIPS depend on the listener being armed, so verifying the chips
            // needs a way to arm it without a real recognizer.
            let silence = MockSilenceDetectionService()
            if !CommandLine.arguments.contains("--ui-test-commands-ready") {
                silence.commandAvailability = .unavailable(reason: "UI-test mock")
            }

            // #212: a scripted room. The host's start goes through the mock
            // network; a guest's host is driven by `hangs-test://room/...`.
            let rooms = MockRoomService()
            network.onStartQuiz = { [rooms] in rooms.beginGame() }
            if CommandLine.arguments.contains("--ui-test-room-nearby") {
                rooms.nearby = [NearbyRoom(roomId: MockRoomService.roomId, hostName: "Michal", hostColor: "#ff6b2c", playerCount: 1)]
            }
            if CommandLine.arguments.contains("--ui-test-room-round") {
                rooms.revealMode = .round
            }

            mockNetwork = network
            mockSilence = silence
            mockAudio = audio
            mockRooms = rooms

            Logger.quiz.info("🧪 UITestSupport: mock services wired (autoConfirmEnabled=false)")
            return (network, audio, persistence, silence, rooms)
        }

        /// #213.4: the Profile's stat cards: a seasoned player, or with
        /// `--ui-test-profile-new` one on the way to the first recap.
        static func makeMockPlayerStats() -> PlayerStatsServiceProtocol {
            let isNew = CommandLine.arguments.contains("--ui-test-profile-new")
            return MockPlayerStatsService(
                results: [.success(isNew ? .mockNewPlayer : .mockSeasoned)],
                recaps: [.success(isNew ? [] : [.mockOctober])]
            )
        }

        /// The player says `text` into the open answer recording (#208.8). The
        /// real batch path runs: the capture receives half a second of audio,
        /// the VAD reports the end of speech, the coordinator uploads the WAV,
        /// and the mock server hears `text` and grades it. Returns false —
        /// the seam fails loudly — when no answer recording is armed.
        @discardableResult
        static func injectSpokenAnswer(_ text: String) async -> Bool {
            guard let network = mockNetwork, let silence = mockSilence else {
                Logger.quiz.error("🧪 UITestSupport: injectSpokenAnswer called but no mocks are registered")
                return false
            }
            // The capture arms a few hops after the probe reads `recording`
            // (engine start, detector session): wait for it, bounded.
            var waitedMs = 0
            while !(silence.isAnswerCaptureActive && silence.isAnswerDetectionActive), waitedMs < 3000 {
                try? await Task.sleep(for: .milliseconds(50))
                waitedMs += 50
            }
            guard silence.isAnswerCaptureActive else {
                Logger.quiz.error("🧪 UITestSupport: injectSpokenAnswer found no armed answer recording")
                return false
            }
            network.nextVoiceTranscript = text
            silence.simulateSilenceEvent(.speechStarted)
            // 0.5 s of 16 kHz 16-bit silence: past the "nothing captured" floor.
            silence.simulateAnswerAudio(Data(count: Int(silence.answerAudioSampleRate)))
            silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.0))
            return true
        }


        /// Register the live command sink. Called by `AppState.sharedQuizViewModel()`
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
        /// - `hangs-test://stt/committed?text=foo` → the player answers "foo" into
        ///   the open recording (`injectSpokenAnswer`; the path name predates #208.8)
        /// - `hangs-test://stt/connected`          → readiness ping, no effect
        /// - `hangs-test://recording/interrupt`    → an audio interruption (phone
        ///   call) hits the recording
        /// - `hangs-test://room/join?text=<token>` → the join link opens (#212)
        /// - `hangs-test://room/start`, `hangs-test://room/next` → a guest's host
        ///   starts the scripted game / moves on (#212)
        /// - `hangs-test://command/send?text=start` → registered command sink("start"),
        ///   driving the real `handleCommandTranscript` → `routeCommand` pipeline
        ///   (issue #111 T3 — voice-command test seam).
        /// Returns `false` when the request was NOT actually handled (unknown
        /// route, or `/command/send` with no sink registered) so the HTTP
        /// listener can answer non-200 and the XCUITest client fails at the
        /// seam — not 15s later at some downstream UI assertion.
        @discardableResult
        static func handleTestURL(_ url: URL) async -> Bool {
            guard url.scheme == "hangs-test" else { return false }

            let host = url.host ?? ""
            let path = url.path
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let text = queryItems.first(where: { $0.name == "text" })?.value ?? ""

            Logger.quiz.info("🧪 UITestSupport: handling URL host=\(host, privacy: .public) path=\(path, privacy: .public)")

            switch (host, path) {
            case ("stt", "/committed"):
                return await injectSpokenAnswer(text)
            case ("stt", "/connected"):
                return true
            case ("recording", "/interrupt"):
                guard let mockAudio else { return false }
                mockAudio.simulateInterruptionBegan()
                return true
            case ("command", "/send"):
                return await handleCommand(text)
            case ("room", "/join"):
                guard let roomInvites, let link = URL(string: "https://trubbo.app/join?t=\(text)") else { return false }
                return roomInvites.receive(link)
            case ("room", "/start"):
                guard let mockRooms else { return false }
                mockRooms.hostStarts()
                return true
            case ("room", "/next"):
                guard let mockRooms else { return false }
                mockRooms.hostMovesOn()
                return true
            default:
                Logger.quiz.error("🧪 UITestSupport: unrecognized URL \(url.absoluteString, privacy: .public)")
                return false
            }
        }

        /// Bind a tiny HTTP server on `127.0.0.1:9999` that translates incoming
        /// requests into the same mock actions as the `hangs-test://` URL
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
        /// status response that reflects whether the request was actually
        /// handled (200 / 404 / 400), then close the connection. Runs on the
        /// listener's dispatch queue; hops to MainActor for the mock injection.
        private nonisolated static func handleConnection(_ connection: NWConnection) {
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let respond: @Sendable (String) -> Void = { status in
                    let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }

                guard
                    let data,
                    let requestText = String(data: data, encoding: .utf8),
                    let firstLine = requestText.split(separator: "\r\n", maxSplits: 1).first
                else {
                    respond("400 Bad Request")
                    return
                }

                let parts = firstLine.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else {
                    respond("400 Bad Request")
                    return
                }
                let method = String(parts[0])
                let pathAndQuery = String(parts[1])
                guard pathAndQuery.hasPrefix("/") else {
                    respond("400 Bad Request")
                    return
                }

                // pathAndQuery is e.g. "/stt/committed?text=Paris" — drop the
                // leading "/" and prepend "hangs-test://" to reuse handleTestURL.
                let urlString = "hangs-test://" + pathAndQuery.dropFirst()
                guard let url = URL(string: urlString) else {
                    respond("400 Bad Request")
                    return
                }

                Logger.quiz.info("🧪 HTTP: \(method, privacy: .public) \(pathAndQuery, privacy: .public)")

                Task { @MainActor in
                    let handled = await UITestSupport.handleTestURL(url)
                    respond(handled ? "200 OK" : "404 Not Found")
                }
            }
        }
    }

#endif
