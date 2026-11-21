//
//  AnalyticsEventsTests.swift
//  HangsTests
//
//  #51 — product analytics. The app emits only what the server cannot see
//  (paywall views, purchase outcomes, how an answer was given, voice
//  commands, abandonment). These pin that each event fires on the transition
//  the metric depends on, with the property values the SQL recipes in
//  `docs/product/analytics-events.md` slice by — a wrong `source` or
//  `input_mode` silently corrupts paywall conversion or voice capture rates.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing

// MARK: - Backend allowlist

/// Copy of `CLIENT_EVENTS` in `apps/quiz-agent/app/analytics/taxonomy.py`. The
/// server DROPS any event or property key not listed there, so a Swift-side
/// rename or typo would lose data without an error anywhere. Change both together.
private let backendClientEvents: [String: Set<String>] = [
    "app_opened": ["launch"],
    "onboarding_finished": ["outcome", "step"],
    "quiz_context": ["audio_route", "voice_commands_enabled", "entry_point", "timezone", "quick_game"],
    // #240.9: reason + question, and `build_channel` on every event below.
    // Added to the server allowlist in its own backend PR.
    "quiz_abandoned": ["questions_answered", "phase", "reason", "question"],
    "answer_submitted": ["input_mode", "question_id", "is_retry", "latency_ms"],
    "voice_capture_failed": ["reason", "question_id"],
    "answer_captured": [
        "question_id", "is_retry", "auto_test", "src_neural_vad", "src_aec", "src_front_mic",
        "neural_vad", "aec", "front_mic", "exp_gen_neural_vad", "exp_gen_aec", "exp_gen_front_mic",
        "route_group", "output_route", "input_route", "stop_reason", "detector", "heard_speech",
        "speech_ms", "end_delay_ms", "duration_ms", "voice_processing", "ec_enabled", "aec_applicable",
        "front_mic_applicable", "mic_data_source", "mic_polar_pattern", "rejected_count",
        "trigger", "mic_open_delay_ms", "peak_db", "mic_permission",
    ],
    "voice_experiment_guard": ["flag", "reason", "from_route", "to_route", "exp_gen"],
    "voice_command": ["command", "phase"],
    "voice_command_window": ["engine", "language", "screen", "transcripts", "matched", "unmatched", "late", "cut_off", "first_transcript_ms"],
    "voice_commands_turned_on": ["source", "result"],
    "paywall_viewed": ["source"],
    "purchase_result": ["product_id", "kind", "outcome", "question_count"],
    "restore_result": ["outcome"],
    "sign_in_prompt_shown": ["kind"],
    "sign_in_prompt_result": ["kind", "outcome"],
    "profile_opened": ["has_account"],
    "recap_viewed": ["kind", "slides_seen", "slides_total"],
    "recap_shared": ["kind"],
    "together_opened": [],
    "room_settings_changed": ["setting", "value", "surface"],
    "room_pause_changed": ["paused", "question"],
    "room_guest_read_aloud": ["on", "via"],
    // #240.9 game together endgame. Added to the server allowlist in its own backend PR.
    "room_closed": ["reason", "players", "questions"],
    "room_ranking_shared": ["role", "players"],
    "home_category_stepped": ["direction", "input", "to"],
    "home_category_picker_opened": ["source"],
    "result_question_opened": ["kind", "verdict"],
    "quick_game_changed": ["enabled"],
    "question_skipped": ["quick"],
    "pack_topic_checked": ["verdict"],
    "shared_quiz_pasted": ["outcome"],
    // #236 family mode (A1). Added to the server allowlist in its own backend PR.
    "family_mode_changed": ["enabled"],
    "family_band_selected": ["band", "first_time"],
    "family_topic_selected": ["band", "topic"],
    "family_topic_empty": ["band", "topic"],
]

/// One instance of every case, with every optional property present.
private let everyEvent: [AnalyticsEvent] = [
    .appOpened(launch: .cold),
    .onboardingFinished(outcome: .commandsOn, step: "commands"),
    .quizContext(audioRoute: .carplay, voiceCommandsEnabled: true, entryPoint: .home, timezone: "Europe/Bratislava", quickGame: true),
    .quizAbandoned(questionsAnswered: 3, phase: "askingQuestion", reason: .endQuiz, question: 4),
    .answerSubmitted(inputMode: .voice, questionId: "q_001", isRetry: false, latencyMs: 1500),
    .voiceCaptureFailed(reason: .tooShort, questionId: "q_001"),
    .answerCaptured(AnswerCapturedReport(
        questionId: "q_001", isRetry: false, autoTest: true,
        flags: Dictionary(uniqueKeysWithValues: VoiceExperimentFlag.allCases.map {
            ($0, VoiceFlagAssignment(isOn: true, source: .auto, generation: 1))
        }),
        routeGroup: .btCar, outputRoute: "CarAudio", inputRoute: "CarAudio", stopReason: .vad,
        detector: "energy", heardSpeech: true, speechMs: 800, endDelayMs: 600, durationMs: 2000,
        voiceProcessing: false, ecEnabled: false, aecApplicable: true, frontMicApplicable: false,
        micDataSource: "none", micPolarPattern: "none", rejectedCount: 0,
        trigger: "auto", micOpenDelayMs: 600, peakDb: -24, micPermission: "granted"
    )),
    .voiceExperimentGuard(flag: .aec, fromRoute: "CarAudio", toRoute: "Speaker", expGen: 1),
    .voiceCommand(command: .next, phase: "result"),
    .voiceCommandWindow(CommandWindowReport(
        engine: "dictation", language: "sk", screen: "question",
        transcripts: 3, matched: 1, unmatched: 1, late: 1, cutOff: 1, firstTranscriptMs: 900
    )),
    .voiceCommandsTurnedOn(source: .listenBar, result: .granted),
    .paywallViewed(source: .quota),
    .purchaseResult(productId: "pack_30", kind: .customPack, outcome: .success, questionCount: 30),
    .restoreResult(outcome: .nothingToRestore),
    .signInPromptShown(kind: .customPack),
    .signInPromptResult(kind: .credit, outcome: .signedIn),
    .profileOpened(hasAccount: true),
    .recapShared(kind: "month"),
    .togetherOpened,
    .roomSettingsChanged(setting: .thinkingSeconds, value: "45", surface: .inGame),
    .roomPauseChanged(paused: true, question: 3),
    .roomGuestReadAloud(on: true, via: "link"),
    .roomClosed(reason: .finished, players: 3, questions: 10),
    .roomRankingShared(role: "host", players: 3),
    .homeCategoryStepped(direction: .next, input: .tap, to: "history"),
    .homeCategoryPickerOpened(source: .deckButton),
    .resultQuestionOpened(kind: .mcq, verdict: .correct),
    .quickGameChanged(enabled: true),
    .questionSkipped(quick: true),
    .packTopicChecked(verdict: "blocked"),
    .sharedQuizPasted(outcome: .notALink),
    .familyModeChanged(enabled: true),
    .familyBandSelected(band: .kids7to9, firstTime: true),
    .familyTopicSelected(band: .kids4to6, topic: "family-dinosaurs"),
    .familyTopicEmpty(band: .kids10to12, topic: "family-harry-potter"),
]

@MainActor
private func makeQuizViewModel(
    analytics: MockAnalyticsClient,
    configure: (MockNetworkService) -> Void = { _ in }
) -> (QuizViewModel, MockNetworkService) {
    let network = Fixtures.makeFullMockNetwork(configure: configure)
    let vm = QuizViewModel(
        networkService: network,
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        clock: AnyClock(TestClock()),
        analytics: analytics
    )
    return (vm, network)
}

@Suite("#51 analytics — taxonomy")
struct AnalyticsTaxonomyTests {
    @Test("every event name and property key is in the backend allowlist")
    func eventsStayInsideTheAllowlist() {
        #expect(Set(everyEvent.map(\.name)).count == everyEvent.count, "one sample per case")
        for event in everyEvent {
            let allowed = backendClientEvents[event.name]
            #expect(allowed != nil, "\(event.name) is not a backend client event — the server would drop it")
            #expect(Set(event.properties.keys).isSubset(of: allowed ?? []), "\(event.name) carries keys the server drops")
        }
    }

    @Test("the wire body matches the ingest contract")
    func batchEncodesTheIngestShape() throws {
        let batch = AnalyticsBatch(events: [AnalyticsBatch.Event(
            name: "answer_submitted",
            occurredAt: Date(timeIntervalSince1970: 0),
            sessionId: "s1",
            properties: AnalyticsEvent.answerSubmitted(inputMode: .tap, questionId: nil, isRetry: true).properties
        )])
        let json = try #require(JSONSerialization.jsonObject(with: batch.encoded()) as? [String: Any])
        let event = try #require((json["events"] as? [[String: Any]])?.first)
        #expect(event["name"] as? String == "answer_submitted")
        #expect(event["occurred_at"] as? String == "1970-01-01T00:00:00Z")
        #expect(event["session_id"] as? String == "s1")
        let properties = try #require(event["properties"] as? [String: Any])
        #expect(properties["input_mode"] as? String == "tap")
        #expect(properties["is_retry"] as? Bool == true)
        #expect(properties["question_id"] == nil, "an unknown question id is left out, never sent as a placeholder")
    }
}

@Suite("#51 analytics — quiz events")
@MainActor
struct QuizAnalyticsTests {
    @Test("paywall_viewed carries the screen that offered it")
    func paywallSourceFromEachEntry() {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)

        vm.presentPaywall(source: .home)
        vm.presentPaywall(source: .settings)
        vm.presentPaywall(source: .completion)

        #expect(analytics.events == [
            .paywallViewed(source: .home),
            .paywallViewed(source: .settings),
            .paywallViewed(source: .completion),
        ])
    }

    @Test("a quota wall on start shows the paywall as source quota")
    func quotaPaywallSource() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics) {
            $0.createSessionError = NetworkError.quotaLimitReached(QuotaLimitError(
                error: "quota_limit_reached", questionsUsed: 30, questionsLimit: 30,
                resetsAt: "2026-11-01T00:00:00+00:00", upgradeAvailable: true
            ))
        }

        await vm.startNewQuiz(pack: PackPlay(packId: "pack-1", questionCount: nil))

        #expect(vm.showPaywall)
        #expect(analytics.events(named: "paywall_viewed") == [.paywallViewed(source: .quota)])
        #expect(analytics.events(named: "quiz_context").isEmpty, "no quiz started")
    }

    @Test("quiz_context fires once the quiz starts, with the entry point and the session")
    func quizContextOnStart() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.settings.voiceCommandsEnabled = false

        await vm.startNewQuiz(pack: PackPlay(packId: "pack-1", questionCount: nil))

        #expect(vm.quizState == .askingQuestion)
        let context = analytics.tracked.filter { $0.event.name == "quiz_context" }
        #expect(context.count == 1)
        guard case let .quizContext(_, voiceCommandsEnabled, entryPoint, timezone, _) = context.first?.event else {
            Issue.record("no quiz_context")
            return
        }
        #expect(entryPoint == .pack)
        #expect(timezone == TimeZone.current.identifier, "analytics occurred_at is UTC; local time of day needs the zone (#213.1)")
        #expect(voiceCommandsEnabled == false)
        #expect(context.first?.sessionId == vm.currentSession?.id, "joins the server's quiz_started")
    }

    @Test("entry point: home, play again, retry")
    func entryPointFromStartingScreen() {
        #expect(QuizEntryPoint(packId: nil, startedFrom: .idle) == .home)
        #expect(QuizEntryPoint(packId: nil, startedFrom: .finished) == .playAgain)
        #expect(QuizEntryPoint(packId: nil, startedFrom: .error(message: "x", context: .initialization)) == .retry)
        #expect(QuizEntryPoint(packId: "p", startedFrom: .finished) == .pack)
    }

    @Test("an MCQ tap is input_mode tap; a second answer to the same question is a retry")
    func answerInputModes() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        await vm.submitMCQAnswer(key: "a", value: "4")
        // The edited answer re-graded from the result screen.
        await vm.resubmitAnswer("5")

        #expect(analytics.events(named: "answer_submitted") == [
            .answerSubmitted(inputMode: .tap, questionId: "q_001", isRetry: false),
            .answerSubmitted(inputMode: .typed, questionId: "q_001", isRetry: true),
        ])
    }

    @Test("a confirmed spoken answer is input_mode voice")
    func spokenAnswerIsVoice() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        await vm.resubmitAnswer("4", spoken: true)

        #expect(analytics.events(named: "answer_submitted") == [
            .answerSubmitted(inputMode: .voice, questionId: "q_001", isRetry: false),
        ])
    }

    @Test("a capture that produced nothing makes the next answer a retry")
    func captureFailureThenRetry() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        vm.recordingCoordinator.trackCaptureFailure(.tooShort)
        await vm.resubmitAnswer("4", spoken: true)

        #expect(analytics.events == [
            .voiceCaptureFailed(reason: .tooShort, questionId: "q_001"),
            .answerSubmitted(inputMode: .voice, questionId: "q_001", isRetry: true),
        ])
    }

    @Test("ending the quiz early is quiz_abandoned with the answered count and phase")
    func endQuizIsAbandoned() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.session(answered: 2)
        vm.quizState = .askingQuestion
        let sessionId = vm.currentSession?.id

        await vm.endQuiz()

        #expect(analytics.tracked == [MockAnalyticsClient.Tracked(
            event: .quizAbandoned(questionsAnswered: 2, phase: "askingQuestion", reason: .endQuiz, question: 3),
            sessionId: sessionId
        )])
    }

    @Test("end & see results is quiz_abandoned too, phase taken before the exit")
    func endWithResultsIsAbandoned() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.session(answered: 1)
        vm.quizState = .askingQuestion

        await vm.endQuizWithResults()

        #expect(analytics.events == [.quizAbandoned(questionsAnswered: 1, phase: "askingQuestion", reason: .endWithResults, question: 2)])
    }

    /// WHY (#240.9): store players left rounds and the data could not say
    /// where or why. Going home from a round's error screen is a way out the
    /// ✕ events never saw.
    @Test("Go Home from a round's error screen is quiz_abandoned with reason error_screen")
    func errorScreenHomeIsAbandoned() {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.session(answered: 4)
        vm.quizState = .error(message: "x", context: .submission)

        vm.resetToHome()

        #expect(analytics.events == [.quizAbandoned(questionsAnswered: 4, phase: QuizState.error(message: "x", context: .submission).label, reason: .errorScreen, question: 5)])
    }

    /// WHY: Home's own Go Home (a finished round's close) is not leaving a round.
    @Test("closing a finished round is not quiz_abandoned")
    func finishedHomeIsNotAbandoned() {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.session(answered: 10)
        vm.quizState = .finished

        vm.resetToHome()

        #expect(analytics.events(named: "quiz_abandoned").isEmpty)
    }

    @Test("a quiz played to the end and closed is NOT abandoned")
    func normalCompletionIsNotAbandoned() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.settleClock = AnyClock(ImmediateClock())
        vm.currentSession = Fixtures.makeActiveSession(phase: "finished")
        vm.quizState = .showingResult(
            question: Fixtures.makeQuestion(id: "q_001"),
            evaluation: Evaluation(
                userAnswer: "4", result: .correct, points: 1.0,
                correctAnswer: "4", questionId: "q_001", explanation: nil
            )
        )

        await vm.proceedToNextQuestion()
        #expect(vm.quizState == .finished)
        vm.resetToHome()

        #expect(analytics.events(named: "quiz_abandoned").isEmpty)
    }

    @Test("a recognised voice command reports its lexicon name and screen")
    func voiceCommandEvent() {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion

        vm.voiceCommandCoordinator.handleRecognizedCommand(.repeatQuestion)

        #expect(analytics.events(named: "voice_command") == [.voiceCommand(command: .repeatQuestion, phase: "question")])
        #expect(analytics.events(named: "voice_command").first?.properties["command"] == .string("repeatQuestion"))
    }
}

@Suite("#51 analytics — purchases")
@MainActor
struct PurchaseAnalyticsTests {
    private func makeStore(
        _ analytics: MockAnalyticsClient,
        configure: (MockPurchaseService) -> Void = { _ in }
    ) async -> StoreManager {
        let purchases = MockPurchaseService()
        configure(purchases)
        let store = StoreManager(purchaseService: purchases, analytics: analytics)
        store.onPurchaseSuccess = { true }
        await pumpUntil({ store.offerings != nil }, "offerings never loaded")
        return store
    }

    @Test("purchase_result reports kind and outcome for each store answer")
    func purchaseOutcomes() async {
        let cases: [(PurchaseOutcome, String, PurchaseKind, PurchaseResultOutcome)] = [
            (.success(unlimitedActive: true), StoreProduct.monthlySubId, .subscription, .success),
            (.userCancelled, StoreProduct.monthlySubId, .subscription, .cancelled),
            (.pending, StoreProduct.packId, .credits, .pending),
            (.success(unlimitedActive: false), StoreProduct.packId, .credits, .success),
        ]
        for (outcome, productId, kind, expected) in cases {
            let analytics = MockAnalyticsClient()
            let store = await makeStore(analytics) { $0.stubbedPurchaseOutcome = outcome }

            await store.purchase(productID: productId)

            #expect(analytics.events == [.purchaseResult(productId: productId, kind: kind, outcome: expected)])
        }
    }

    @Test("a store error is a failed purchase")
    func purchaseFailure() async {
        let analytics = MockAnalyticsClient()
        let store = await makeStore(analytics) { $0.stubbedPurchaseError = NetworkError.invalidResponse }

        await store.purchase(productID: StoreProduct.monthlySubId)

        #expect(analytics.events == [.purchaseResult(productId: StoreProduct.monthlySubId, kind: .subscription, outcome: .failed)])
    }

    @Test("restore_result: nothing to restore vs failed")
    func restoreOutcomes() async {
        let analytics = MockAnalyticsClient()
        let store = await makeStore(analytics)
        store.onPurchaseSuccess = { false }

        await store.restorePurchases()

        #expect(analytics.events == [.restoreResult(outcome: .nothingToRestore)])
    }

    @Test("a custom pack payment sheet reports custom_pack, cancelled included")
    func customPackPurchase() async {
        let analytics = MockAnalyticsClient()
        let vm = OrderPackViewModel(
            service: MockPackOrderService(),
            purchaseService: MockPackPurchaseService(purchaseResult: .failure(.cancelled)),
            adminKeyAvailable: { false },
            clock: AnyClock(ImmediateClock()),
            analytics: analytics
        )
        vm.prompt = "Dinosaurs"
        vm.selectDifficulty(.medium)
        vm.advanceToSummary()

        await vm.submit()

        #expect(analytics.events == [.purchaseResult(
            productId: "pack_30", kind: .customPack, outcome: .cancelled, questionCount: 30
        )])
    }
}

@Suite("#51 analytics — app lifecycle and onboarding")
@MainActor
struct AppLifecycleAnalyticsTests {
    @Test("app_opened: cold once, foreground only after a trip to the background")
    func appOpenedLaunchKinds() {
        let analytics = MockAnalyticsClient()
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            analytics: analytics
        )

        appState.trackScenePhase(.background) // launch order varies — still a cold open
        appState.trackScenePhase(.active)
        appState.trackScenePhase(.inactive) // Control Center: not a new open
        appState.trackScenePhase(.active)
        appState.trackScenePhase(.background)
        appState.trackScenePhase(.active)

        #expect(analytics.events == [.appOpened(launch: .cold), .appOpened(launch: .foreground)])
        #expect(analytics.flushCount == 2, "queued events go out every time the app leaves")
    }
}

@Suite("#51 analytics — live client batching")
@MainActor
struct LiveAnalyticsClientTests {
    @Test("events wait for the timer, then go out as one batch with the session id")
    func flushesOnTimer() async {
        let network = MockNetworkService()
        let clock = TestClock<Duration>()
        let client = LiveAnalyticsClient(networkService: network, clock: AnyClock(clock))

        client.track(.paywallViewed(source: .home))
        client.track(.quizAbandoned(questionsAnswered: 1, phase: "askingQuestion", reason: .endQuiz, question: 2), sessionId: "s1")
        await clock.advance(by: LiveAnalyticsClient.flushDelay - .milliseconds(1))
        #expect(network.postedAnalyticsBatches.isEmpty, "nothing before the timer")

        await clock.advance(by: .milliseconds(1))
        await pumpUntil({ network.postedAnalyticsBatches.count == 1 }, "the timer never flushed")
        let events = network.postedAnalyticsBatches.first?.events ?? []
        #expect(events.map(\.name) == ["paywall_viewed", "quiz_abandoned"])
        #expect(events.map(\.sessionId) == [nil, "s1"])
    }

    /// WHY (#240.9): the store cohort's numbers were read next to testers'
    /// and debug runs. Every event carries the channel it came from.
    @Test("every event carries build_channel")
    func everyEventCarriesBuildChannel() async {
        let network = MockNetworkService()
        let client = LiveAnalyticsClient(networkService: network, clock: AnyClock(TestClock()), buildChannel: "testflight")

        client.track(.paywallViewed(source: .home))
        client.track(.togetherOpened)
        client.flush()
        await pumpUntil({ network.postedAnalyticsBatches.count == 1 }, "flush() never sent")

        let channels = network.postedAnalyticsBatches.first?.events.map { $0.properties["build_channel"] }
        #expect(channels == [.string("testflight"), .string("testflight")])
    }

    @Test("build_channel: the App Store variant wins, then debug, then the receipt")
    func buildChannelValue() {
        let sandbox = URL(fileURLWithPath: "/x/sandboxReceipt")
        let store = URL(fileURLWithPath: "/x/receipt")
        #expect(BuildChannel.analyticsValue(receiptURL: sandbox, isDebugBuild: false, isAppStoreBuild: true) == "app_store")
        #expect(BuildChannel.analyticsValue(receiptURL: sandbox, isDebugBuild: true, isAppStoreBuild: false) == "debug")
        #expect(BuildChannel.analyticsValue(receiptURL: sandbox, isDebugBuild: false, isAppStoreBuild: false) == "testflight")
        #expect(BuildChannel.analyticsValue(receiptURL: store, isDebugBuild: false, isAppStoreBuild: false) == "app_store")
    }

    @Test("a full queue flushes at once; background flush sends the rest")
    func flushesOnThresholdAndBackground() async {
        let network = MockNetworkService()
        let client = LiveAnalyticsClient(networkService: network, clock: AnyClock(TestClock()))

        for _ in 0 ..< LiveAnalyticsClient.batchThreshold {
            client.track(.paywallViewed(source: .home))
        }
        await pumpUntil({ network.postedAnalyticsBatches.count == 1 }, "threshold never flushed")
        #expect(network.postedAnalyticsBatches.first?.events.count == LiveAnalyticsClient.batchThreshold)

        client.track(.restoreResult(outcome: .success))
        client.flush()
        await pumpUntil({ network.postedAnalyticsBatches.count == 2 }, "flush() never sent")
        #expect(network.postedAnalyticsBatches.last?.events.map(\.name) == ["restore_result"])
    }

    @Test("a failed post is tried once more, then dropped — never piled up")
    func retriesOnceThenDrops() async {
        let network = MockNetworkService()
        network.analyticsPostFailures = 5
        let client = LiveAnalyticsClient(networkService: network, clock: AnyClock(TestClock()))

        client.track(.paywallViewed(source: .home))
        client.flush()
        await pumpUntil({ network.postedAnalyticsBatches.count == 2 }, "no second attempt")
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(network.postedAnalyticsBatches.count == LiveAnalyticsClient.maxAttempts)

        client.flush()
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(network.postedAnalyticsBatches.count == LiveAnalyticsClient.maxAttempts, "a dropped batch is not re-queued")
    }
}

@Suite("#213.1 answer latency")
@MainActor
struct AnswerLatencyTests {
    private func makeTracker() -> (AnswerLatencyTracker, TestClock<Duration>) {
        let clock = TestClock()
        return (AnswerLatencyTracker(clock: AnyClock(clock)), clock)
    }

    @Test("event properties carry latency_ms only when known")
    func eventCarriesLatency() {
        let known = AnalyticsEvent.answerSubmitted(inputMode: .tap, questionId: "q", isRetry: false, latencyMs: 2300)
        #expect(known.properties["latency_ms"] == .int(2300))
        let unknown = AnalyticsEvent.answerSubmitted(inputMode: .tap, questionId: "q", isRetry: true)
        #expect(unknown.properties["latency_ms"] == nil, "unknown start is omitted, never sent as 0")
    }

    @Test("quiz_context carries the IANA timezone")
    func contextCarriesTimezone() {
        let event = AnalyticsEvent.quizContext(
            audioRoute: .speaker, voiceCommandsEnabled: true, entryPoint: .home, timezone: "Europe/Bratislava"
        )
        #expect(event.properties["timezone"] == .string("Europe/Bratislava"))
    }

    @Test("a tap is measured from the window opening to the submit moment")
    func tapLatency() async {
        let (tracker, clock) = makeTracker()
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(3200))
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: false) == 3200)
    }

    @Test("a voice answer ends at speech onset, not at submit")
    func voiceLatencyUsesOnset() async {
        let (tracker, clock) = makeTracker()
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(1000)) // recording runs 1000..6000 ms
        await clock.advance(by: .milliseconds(5000))
        tracker.noteSpeechOnset(durationMs: 5000, firstSpeechMs: 1500)
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: true) == 2500)
    }

    @Test("a voice answer without a measured onset falls back to the submit moment")
    func voiceWithoutOnset() async {
        let (tracker, clock) = makeTracker()
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(4000))
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: true) == 4000)
    }

    @Test("paused time is excluded")
    func pausedTimeExcluded() async {
        let (tracker, clock) = makeTracker()
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(1000))
        tracker.setPaused(true)
        await clock.advance(by: .milliseconds(30000))
        tracker.setPaused(false)
        await clock.advance(by: .milliseconds(500))
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: false) == 1500)
    }

    @Test("a retry, an unopened window and another question's window report nothing")
    func unknownStartIsOmitted() async {
        let (tracker, clock) = makeTracker()
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: false) == nil, "tap mid-read")
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(100))
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: true, voice: false) == nil, "retry")
        tracker.openWindow(questionId: "q1")
        tracker.openWindow(questionId: "q2")
        await clock.advance(by: .milliseconds(100))
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: false) == nil, "wrong question")
    }

    @Test("re-arming the think timer does not restart the window")
    func openIsIdempotent() async {
        let (tracker, clock) = makeTracker()
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(1000))
        tracker.openWindow(questionId: "q1")
        await clock.advance(by: .milliseconds(1000))
        #expect(tracker.consumeLatencyMs(questionId: "q1", isRetry: false, voice: false) == 2000)
    }
}
