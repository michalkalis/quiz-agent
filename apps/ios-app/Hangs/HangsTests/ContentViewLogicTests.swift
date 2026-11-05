//
//  ContentViewLogicTests.swift
//  HangsTests
//
//  #194 A1: the root's logic moved out of ContentView — routing (`QuizScreen`),
//  the post-purchase sign-in prompt (`SignInPromptCoordinator`), the error
//  screen's retry (`retryFromErrorScreen`) and the feedback sheet factory. The
//  redesign restyles every root screen; these pin what the root decides.
//

import Foundation
@testable import Hangs
import os
import Testing
import UIKit

private nonisolated final class StubTokenStore: TokenStore, @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<AuthTokens?>

    init(_ tokens: AuthTokens? = nil) {
        lock = OSAllocatedUnfairLock(initialState: tokens)
    }

    func load() -> AuthTokens? { lock.withLock { $0 } }
    func save(_ tokens: AuthTokens) { lock.withLock { $0 = tokens } }
    func clear() { lock.withLock { $0 = nil } }
}

@Suite("Root routing per quiz state (#194 A1)")
@MainActor
struct QuizScreenRoutingTests {
    @Test("every quiz state lands on its screen")
    func stateToScreen() {
        let vm = Fixtures.makeViewModel()
        let cases: [(QuizState, QuizScreen)] = [
            (.idle, .home),
            (.startingQuiz, .home),
            (.askingQuestion, .question),
            (.awaitingQuestion, .question),
            (.recording, .question),
            (.processing, .question),
            (.skipping, .question),
            (.showingResult(question: Question.preview, evaluation: .previewCorrect), .result),
            (.finished, .completion),
        ]
        for (state, screen) in cases {
            vm.quizState = state
            #expect(vm.quizScreen == screen, "\(state.label)")
        }
    }

    /// #132 E: an end-of-set reveal with nothing recorded must not end on an
    /// empty recap list.
    @Test("an empty recap degrades to the score screen")
    func emptyRecapDegrades() {
        let vm = Fixtures.makeViewModel()
        vm.settings.answerRevealMode = .endOfSet
        vm.quizState = .finished
        #expect(vm.quizScreen == .completion)
    }

    @Test("the error screen uses the error's model, or the context's fallback")
    func errorModel() {
        let vm = Fixtures.makeViewModel()
        vm.quizState = .error(message: "x", context: .submission)
        #expect(vm.quizScreen == .error(AppErrorModel.from(context: .submission)))

        let custom = AppErrorModel(title: "T", description: "D", retryAction: .goHome)
        vm.quizState = .askingQuestion
        vm.setError(message: "x", context: .general, model: custom)
        #expect(vm.quizScreen == .error(custom))
    }
}

@Suite("Error screen retry (#194 A1)")
@MainActor
struct ErrorScreenRetryTests {
    /// A failed step mid-quiz goes back to the question, it does not restart.
    @Test("a submission error returns to the question without a new session")
    func submissionRetryReturnsToQuestion() async {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.quizState = .error(message: "x", context: .submission)
        vm.errorMessage = "x"

        await vm.retryFromErrorScreen().value

        #expect(vm.quizState == .askingQuestion)
        #expect(vm.errorMessage == nil)
        #expect(network.createSessionCallCount == 0)
    }

    @Test("a failed start retries with a new session")
    func initializationRetryStartsNewSession() async {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.quizState = .error(message: "x", context: .initialization)

        await vm.retryFromErrorScreen().value

        #expect(network.createSessionCallCount == 1)
    }
}

@Suite("Post-purchase sign-in prompt (#194 A1, #217.4)")
@MainActor
struct SignInPromptCoordinatorTests {
    private static let signedIn = AuthTokens(
        accessToken: "a", refreshToken: "r", anonId: "u",
        accountName: nil, accountEmail: nil, appleUserId: "apple"
    )
    private static let pack = SignInPromptPurchase.customPack(name: "Harry Potter", questionCount: 30, colorKey: "o1")

    @Test("a signed-out buyer at rest is prompted at once, it counts and is tracked")
    func promptsImmediately() {
        let store = MockPersistenceStore()
        let analytics = MockAnalyticsClient()
        let coordinator = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore(), analytics: analytics)

        coordinator.purchaseCompleted(.plus, canPresentNow: true)

        #expect(coordinator.presented == .plus)
        #expect(store.signInPromptShownCount == 1)
        #expect(analytics.events == [.signInPromptShown(kind: .plus)])
    }

    /// #217.4: credit and custom packs are lost on a new phone without an
    /// account (Apple restores only Plus), so their purchases prompt too.
    @Test("credit and custom pack purchases prompt like Plus", arguments: [
        SignInPromptPurchase.credit(questionCount: 100),
        SignInPromptPurchase.customPack(name: "Harry Potter", questionCount: 30, colorKey: "o1"),
    ])
    func creditAndPackPrompt(purchase: SignInPromptPurchase) {
        let coordinator = SignInPromptCoordinator(persistenceStore: MockPersistenceStore(), tokenStore: StubTokenStore())

        coordinator.purchaseCompleted(purchase, canPresentNow: true)

        #expect(coordinator.presented == purchase)
    }

    /// Two sheets cannot overlap: the prompt waits for the paywall / order flow / quiz.
    @Test("a purchase made on another screen prompts only once the app is at rest")
    func waitsForRest() {
        let coordinator = SignInPromptCoordinator(persistenceStore: MockPersistenceStore(), tokenStore: StubTokenStore())

        coordinator.purchaseCompleted(.credit(questionCount: 100), canPresentNow: false)
        #expect(coordinator.presented == nil)

        coordinator.presentPendingIfAny()
        #expect(coordinator.presented == .credit(questionCount: 100))

        coordinator.finish(.dismissed)
        coordinator.presentPendingIfAny()
        #expect(coordinator.presented == nil, "a later rest must not re-prompt")
    }

    @Test("a second purchase before the waiting prompt shows replaces it, counted once")
    func secondPurchaseWhileWaiting() {
        let store = MockPersistenceStore()
        let coordinator = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore())

        coordinator.purchaseCompleted(.credit(questionCount: 100), canPresentNow: false)
        coordinator.purchaseCompleted(Self.pack, canPresentNow: false)
        coordinator.presentPendingIfAny()

        #expect(coordinator.presented == Self.pack)
        #expect(store.signInPromptShownCount == 1)
    }

    @Test("no prompt for a signed-in user, also when they signed in while it waited")
    func signedInNeverPrompted() {
        let store = MockPersistenceStore()
        let signedInCoordinator = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore(Self.signedIn))
        signedInCoordinator.purchaseCompleted(.plus, canPresentNow: true)
        #expect(signedInCoordinator.presented == nil)
        #expect(store.signInPromptShownCount == 0)

        let tokens = StubTokenStore()
        let waiting = SignInPromptCoordinator(persistenceStore: MockPersistenceStore(), tokenStore: tokens)
        waiting.purchaseCompleted(Self.pack, canPresentNow: false)
        tokens.save(Self.signedIn)
        waiting.presentPendingIfAny()
        #expect(waiting.presented == nil)
    }

    /// The cap is shared: a Plus prompt and a pack prompt use it up together.
    @Test("no prompt past the cap, across all purchase kinds")
    func capAcrossKinds() {
        let store = MockPersistenceStore()
        let coordinator = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore())

        coordinator.purchaseCompleted(.plus, canPresentNow: true)
        coordinator.finish(.dismissed)
        coordinator.purchaseCompleted(.credit(questionCount: 100), canPresentNow: true)
        coordinator.finish(.dismissed)
        coordinator.purchaseCompleted(Self.pack, canPresentNow: true)

        #expect(coordinator.presented == nil)
        #expect(store.signInPromptShownCount == SignInPromptGate.maxPresentations)
    }

    /// The prompt's funnel: shown → signed in or dismissed, once per showing
    /// (a button close is followed by the sheet's own dismiss callback).
    @Test("the outcome is tracked once, a swipe down as dismissed")
    func outcomeTrackedOnce() {
        let analytics = MockAnalyticsClient()
        let coordinator = SignInPromptCoordinator(persistenceStore: MockPersistenceStore(), tokenStore: StubTokenStore(), analytics: analytics)

        coordinator.purchaseCompleted(Self.pack, canPresentNow: true)
        coordinator.finish(.signedIn)
        coordinator.sheetDismissed()
        #expect(analytics.events(named: "sign_in_prompt_result") == [.signInPromptResult(kind: .customPack, outcome: .signedIn)])

        let swiped = MockAnalyticsClient()
        let other = SignInPromptCoordinator(persistenceStore: MockPersistenceStore(), tokenStore: StubTokenStore(), analytics: swiped)
        other.purchaseCompleted(.credit(questionCount: 100), canPresentNow: true)
        other.presented = nil
        other.sheetDismissed()
        #expect(swiped.events(named: "sign_in_prompt_result") == [.signInPromptResult(kind: .credit, outcome: .dismissed)])
    }
}

/// #217.4 (task brief 2026-11-04): signing in from the prompt re-keys the
/// phone's purchases to the account, and Play and Profile sit behind the
/// sheet without reappearing, so they must load the account's data again or
/// the player would see the old (anonymous) packs, credit and stats.
@Suite("Reload after sign-in (#217.4)")
@MainActor
struct ReloadAfterSignInTests {
    @Test("packs, stats and usage are fetched again")
    func reloads() async {
        let network = Fixtures.makeFullMockNetwork()
        let packs = MockPackOrderService()
        let stats = MockPlayerStatsService()
        let appState = AppState(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            packOrderService: packs,
            playerStatsService: stats
        )
        _ = appState.sharedQuizViewModel()
        let usageBefore = network.getUsageCallCount
        let listBefore = packs.listOrdersCallCount
        let statsBefore = stats.fetchCount

        await appState.reloadAfterSignIn()

        #expect(packs.listOrdersCallCount == listBefore + 1)
        #expect(stats.fetchCount == statsBefore + 1)
        #expect(network.getUsageCallCount > usageBefore)
    }
}

@Suite("Feedback sheet factory (#194 A1)")
@MainActor
struct FeedbackPresentationFactoryTests {
    /// The screenshot is taken by the caller BEFORE the sheet presents; the
    /// factory must attach exactly that shot.
    @Test("the presentation carries the screenshot taken before it")
    func carriesScreenshot() {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let shot = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }

        let presentation = appState.makeFeedbackPresentation(for: Fixtures.makeViewModel(), screenshot: shot)

        #expect(presentation.viewModel.screenshot === shot)
    }
}
