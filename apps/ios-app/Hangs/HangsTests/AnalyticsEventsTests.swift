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
    "quiz_context": ["audio_route", "voice_commands_enabled", "entry_point"],
    "quiz_abandoned": ["questions_answered", "phase"],
    "answer_submitted": ["input_mode", "question_id", "is_retry"],
    "voice_capture_failed": ["reason", "question_id"],
    "voice_command": ["command", "phase"],
    "quiz_minimized": ["phase"],
    "paywall_viewed": ["source"],
    "purchase_result": ["product_id", "kind", "outcome"],
    "restore_result": ["outcome"],
]

/// One instance of every case, with every optional property present.
private let everyEvent: [AnalyticsEvent] = [
    .appOpened(launch: .cold),
    .onboardingFinished(outcome: .micGranted, step: "permission"),
    .quizContext(audioRoute: .carplay, voiceCommandsEnabled: true, entryPoint: .home),
    .quizAbandoned(questionsAnswered: 3, phase: "askingQuestion"),
    .answerSubmitted(inputMode: .voice, questionId: "q_001", isRetry: false),
    .voiceCaptureFailed(reason: .tooShort, questionId: "q_001"),
    .voiceCommand(command: .next, phase: "result"),
    .paywallViewed(source: .quota),
    .purchaseResult(productId: "pack_30", kind: .customPack, outcome: .success),
    .restoreResult(outcome: .nothingToRestore),
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

        await vm.startNewQuiz(packId: "pack-1")

        #expect(vm.showPaywall)
        #expect(analytics.events(named: "paywall_viewed") == [.paywallViewed(source: .quota)])
        #expect(analytics.events(named: "quiz_context").isEmpty, "no quiz started")
    }

    @Test("quiz_context fires once the quiz starts, with the entry point and the session")
    func quizContextOnStart() async {
        let analytics = MockAnalyticsClient()
        let (vm, _) = makeQuizViewModel(analytics: analytics)
        vm.settings.voiceCommandsEnabled = false

        await vm.startNewQuiz(packId: "pack-1")

        #expect(vm.quizState == .askingQuestion)
        let context = analytics.tracked.filter { $0.event.name == "quiz_context" }
        #expect(context.count == 1)
        guard case let .quizContext(_, voiceCommandsEnabled, entryPoint) = context.first?.event else {
            Issue.record("no quiz_context")
            return
        }
        #expect(entryPoint == .pack)
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
            event: .quizAbandoned(questionsAnswered: 2, phase: "askingQuestion"),
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

        #expect(analytics.events == [.quizAbandoned(questionsAnswered: 1, phase: "askingQuestion")])
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
        vm.advanceToSummary()

        await vm.submit()

        #expect(analytics.events == [.purchaseResult(
            productId: StoreKitPackPurchaseService.productId, kind: .customPack, outcome: .cancelled
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

    @Test("onboarding_finished says how and where it ended")
    func onboardingOutcomes() async {
        let analytics = MockAnalyticsClient()
        let audio = MockAudioService()
        let skipped = OnboardingViewModel(audioService: audio, persistenceStore: MockPersistenceStore(), analytics: analytics)
        skipped.continueWithoutMic()

        let granted = OnboardingViewModel(audioService: audio, persistenceStore: MockPersistenceStore(), analytics: analytics)
        granted.advance()
        granted.advance()
        await granted.requestMicPermission()

        #expect(analytics.events == [
            .onboardingFinished(outcome: .skipped, step: "welcome"),
            .onboardingFinished(outcome: .micGranted, step: "permission"),
        ])
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
        client.track(.quizAbandoned(questionsAnswered: 1, phase: "askingQuestion"), sessionId: "s1")
        await clock.advance(by: LiveAnalyticsClient.flushDelay - .milliseconds(1))
        #expect(network.postedAnalyticsBatches.isEmpty, "nothing before the timer")

        await clock.advance(by: .milliseconds(1))
        await pumpUntil({ network.postedAnalyticsBatches.count == 1 }, "the timer never flushed")
        let events = network.postedAnalyticsBatches.first?.events ?? []
        #expect(events.map(\.name) == ["paywall_viewed", "quiz_abandoned"])
        #expect(events.map(\.sessionId) == [nil, "s1"])
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
