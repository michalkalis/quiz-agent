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

@Suite("Post-purchase sign-in prompt (#194 A1)")
@MainActor
struct SignInPromptCoordinatorTests {
    @Test("a signed-out buyer outside the paywall is prompted at once, and it counts")
    func promptsImmediately() {
        let store = MockPersistenceStore()
        let coordinator = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore())

        coordinator.premiumActivated(whilePaywallShown: false)

        #expect(coordinator.isPresented)
        #expect(store.signInPromptShownCount == 1)
    }

    /// Two sheets cannot overlap: the prompt waits for the paywall to close.
    @Test("a purchase from the paywall prompts only after the paywall is dismissed")
    func waitsForPaywall() {
        let coordinator = SignInPromptCoordinator(persistenceStore: MockPersistenceStore(), tokenStore: StubTokenStore())

        coordinator.premiumActivated(whilePaywallShown: true)
        #expect(!coordinator.isPresented)

        coordinator.paywallDismissed()
        #expect(coordinator.isPresented)

        coordinator.isPresented = false
        coordinator.paywallDismissed()
        #expect(!coordinator.isPresented, "a later paywall close must not re-prompt")
    }

    @Test("no prompt for a signed-in user or past the cap")
    func gated() {
        let signedIn = AuthTokens(
            accessToken: "a", refreshToken: "r", anonId: "u",
            accountName: nil, accountEmail: nil, appleUserId: "apple"
        )
        let store = MockPersistenceStore()
        let signedInCoordinator = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore(signedIn))
        signedInCoordinator.premiumActivated(whilePaywallShown: false)
        #expect(!signedInCoordinator.isPresented)
        #expect(store.signInPromptShownCount == 0)

        store.signInPromptShownCount = SignInPromptGate.maxPresentations
        let capped = SignInPromptCoordinator(persistenceStore: store, tokenStore: StubTokenStore())
        capped.premiumActivated(whilePaywallShown: false)
        #expect(!capped.isPresented)
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
