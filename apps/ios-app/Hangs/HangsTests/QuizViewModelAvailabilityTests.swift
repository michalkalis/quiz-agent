//
//  QuizViewModelAvailabilityTests.swift
//  HangsTests
//
//  #174 finding 1: a set of 10 must never silently end after 3.
//

import Testing
@testable import Hangs

/// The founder configured 10 questions and the quiz ended after 3 with "1/3":
/// the backend ran out of eligible unseen questions and quietly finished the
/// session. The fix is a pre-flight probe, so what these tests protect is the
/// DECISION made from it — start, or stop and let the user choose — not the
/// count itself (that is the backend's test).
@Suite("Question availability pre-check (#174)")
@MainActor
struct QuizViewModelAvailabilityTests {
    private func makeViewModel(
        available: Int?,
        requested: Int,
        seenIds: [String] = []
    ) -> (QuizViewModel, MockNetworkService, MockPersistenceStore) {
        let network = Fixtures.makeFullMockNetwork { mock in
            if let available {
                mock.stubbedAvailability = QuestionAvailability(
                    available: available,
                    requested: requested,
                    sufficient: available >= requested
                )
            }
        }
        let store = MockPersistenceStore()
        store.askedQuestionIds = seenIds
        let viewModel = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: store
        )
        return (viewModel, network, store)
    }

    @Test("A short corpus stops the start and raises the shortfall instead")
    func shortCorpusStopsTheStart() async {
        let (viewModel, network, _) = makeViewModel(available: 3, requested: 10)

        await viewModel.startNewQuiz(maxQuestions: 10)

        // The quiz must NOT have started: starting is precisely the failure the
        // founder saw (a promised 10 that dies at 3).
        #expect(viewModel.quizState == .idle)
        #expect(network.createSessionCallCount == 0)
        #expect(viewModel.questionShortfall?.available == 3)
        #expect(viewModel.questionShortfall?.requested == 10)
        // "Start with 3 questions" is offered — 3 is still a playable set.
        #expect(viewModel.questionShortfall?.canStartShorter == true)
    }

    @Test("Zero available hides the shorter-set button")
    func zeroAvailableHidesShorterStart() async {
        let (viewModel, _, _) = makeViewModel(available: 0, requested: 10)

        await viewModel.startNewQuiz(maxQuestions: 10)

        // A zero-question quiz is not a quiz, so the alert must leave only
        // "Reset seen questions" and "Cancel".
        #expect(viewModel.questionShortfall?.canStartShorter == false)
    }

    @Test("Enough questions starts the quiz with no alert")
    func sufficientCorpusStartsNormally() async {
        let (viewModel, network, _) = makeViewModel(available: 40, requested: 10)

        await viewModel.startNewQuiz(maxQuestions: 10)

        // The happy path must stay silent — an advisory check that interrupts a
        // playable quiz is worse than the bug it fixes.
        #expect(viewModel.questionShortfall == nil)
        #expect(viewModel.quizState == .askingQuestion)
        #expect(network.capturedMaxQuestions == 10)
    }

    @Test("A failed probe starts the quiz anyway (fails open)")
    func probeFailureDoesNotBlockTheQuiz() async {
        let (viewModel, network, _) = makeViewModel(available: nil, requested: 10)
        network.questionAvailabilityError = NetworkError.invalidResponse

        await viewModel.startNewQuiz(maxQuestions: 10)

        // A network hiccup on an ADVISORY check must never cost the user a quiz
        // they could have played; the degraded behaviour is the pre-#174 one.
        #expect(viewModel.questionShortfall == nil)
        #expect(viewModel.quizState == .askingQuestion)
    }

    @Test("Start with N starts a session of exactly N")
    func startWithAvailableUsesTheHonestCount() async throws {
        let (viewModel, network, _) = makeViewModel(available: 3, requested: 10)
        await viewModel.startNewQuiz(maxQuestions: 10)

        let shortfall = try #require(viewModel.questionShortfall)
        await viewModel.startWithAvailableQuestions(shortfall)?.value

        // The progress label reads the session length, so an honest "3" here is
        // the whole point: the user is told 3 and gets 3.
        #expect(network.capturedMaxQuestions == 3)
        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.questionShortfall == nil)
        // No second probe: re-checking would re-open the alert just answered.
        #expect(network.questionAvailabilityCallCount == 1)
    }

    @Test("Start with N is a no-op when nothing is available")
    func startWithAvailableRefusesZero() async throws {
        let (viewModel, network, _) = makeViewModel(available: 0, requested: 10)
        await viewModel.startNewQuiz(maxQuestions: 10)

        let shortfall = try #require(viewModel.questionShortfall)
        await viewModel.startWithAvailableQuestions(shortfall)?.value

        // Guards the button the UI hides at N == 0 — a voice/accessibility path
        // reaching the action anyway must not create a zero-question session.
        #expect(network.createSessionCallCount == 0)
        #expect(viewModel.quizState == .idle)
    }

    @Test("Reset clears the seen history, re-checks, then starts the full set")
    func resetClearsHistoryAndRestarts() async throws {
        let (viewModel, network, store) = makeViewModel(
            available: 3, requested: 10, seenIds: ["q1", "q2", "q3"]
        )
        await viewModel.startNewQuiz(maxQuestions: 10)
        // A reset makes the whole corpus eligible again, which is what the
        // second probe would now report.
        network.stubbedAvailability = QuestionAvailability(available: 40, requested: 10, sufficient: true)

        let shortfall = try #require(viewModel.questionShortfall)
        await viewModel.resetSeenQuestionsAndStart(shortfall).value

        // The old history is gone (the new quiz's own first question is back in
        // it already, which is why this asserts absence rather than emptiness).
        #expect(!store.askedQuestionIds.contains("q1"))
        // Cleared BEFORE the re-check, so the second probe sees a clean slate —
        // otherwise the reset would report the same shortfall it just cleared.
        #expect(network.capturedAvailabilityExcludedIds == [])
        // Deliberately re-probes: if the category is still too small the user
        // must see that rather than be dropped into another short set.
        #expect(network.questionAvailabilityCallCount == 2)
        #expect(network.capturedMaxQuestions == 10)
        #expect(viewModel.quizState == .askingQuestion)
    }

    @Test("Reset that does not free enough questions re-raises the shortfall")
    func resetStillShortRaisesTheAlertAgain() async throws {
        let (viewModel, network, _) = makeViewModel(available: 2, requested: 10, seenIds: ["q1"])
        await viewModel.startNewQuiz(maxQuestions: 10)
        network.stubbedAvailability = QuestionAvailability(available: 5, requested: 10, sufficient: false)

        let shortfall = try #require(viewModel.questionShortfall)
        await viewModel.resetSeenQuestionsAndStart(shortfall).value

        // Honesty over convenience: a fresh history that still cannot cover 10
        // must ask again with the new number, not start a silent short set.
        #expect(viewModel.questionShortfall?.available == 5)
        #expect(network.createSessionCallCount == 0)
    }

    @Test("An alert-initiated start is cancellable like any other")
    func alertStartIsRegisteredForCancellation() async throws {
        let (viewModel, network, _) = makeViewModel(available: 3, requested: 10)
        await viewModel.startNewQuiz(maxQuestions: 10)
        let shortfall = try #require(viewModel.questionShortfall)
        network.onCreateSession = { [weak viewModel] in viewModel?.cancelQuizStart() }

        await viewModel.startWithAvailableQuestions(shortfall)?.value

        // A start the taskBag does not hold under `.quizStart` is invisible to
        // Home's "Cancel" and to `resetState`'s `cancelAll`, so it would run on
        // past a teardown; landing on .idle proves this one is held.
        #expect(viewModel.quizState == .idle)
        #expect(!viewModel.quizState.isError)
    }

    @Test("Cancel dismisses without starting anything")
    func cancelDismissesWithoutStarting() async {
        let (viewModel, network, store) = makeViewModel(
            available: 3, requested: 10, seenIds: ["q1"]
        )
        await viewModel.startNewQuiz(maxQuestions: 10)

        viewModel.dismissQuestionShortfall()

        #expect(viewModel.questionShortfall == nil)
        #expect(network.createSessionCallCount == 0)
        // Cancel must not touch the history — only the explicit reset button does.
        #expect(store.askedQuestionIds == ["q1"])
    }

    @Test("The probe carries the seen history it is asking about")
    func probeSendsTheExclusionList() async {
        let (viewModel, network, _) = makeViewModel(
            available: 40, requested: 10, seenIds: ["q1", "q2"]
        )

        await viewModel.startNewQuiz(maxQuestions: 10)

        // "Unseen" is the whole question — a probe without the history would
        // report the full corpus and never fire the alert.
        #expect(network.capturedAvailabilityExcludedIds == ["q1", "q2"])
        #expect(network.capturedAvailabilityRequestedCount == 10)
    }

    @Test("A custom pack skips the probe entirely")
    func packSessionSkipsTheProbe() async {
        let (viewModel, network, _) = makeViewModel(available: 0, requested: 10)

        await viewModel.startNewQuiz(maxQuestions: 10, packId: "pack-1")

        // A pack is a closed, paid, exactly-sized set served from its own pool,
        // so the shared-corpus count says nothing about it and must not block it.
        #expect(network.questionAvailabilityCallCount == 0)
        #expect(viewModel.quizState == .askingQuestion)
    }
}
