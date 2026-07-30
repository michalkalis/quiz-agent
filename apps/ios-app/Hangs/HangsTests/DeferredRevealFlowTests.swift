//
//  DeferredRevealFlowTests.swift
//  HangsTests
//
//  #132 Track E — deferred answer reveal. The founder-decided behavior under
//  test: with "Odhalenie odpovedí = Na konci sady" there is NO interstitial —
//  no result screen, no spoken verdict — the next question appears immediately
//  after an answer/skip, and the whole set is revealed once, on the recap.
//  The default (per-question) flow must be bit-for-bit today's flow.
//

import Foundation
@testable import Hangs
import Testing

// MARK: - Helpers (self-contained per the race-tests convention)

/// Spin until `predicate` is true (sync @MainActor state).
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 10000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

@MainActor
private func makeResponse(
    result: Evaluation.EvaluationResult,
    userAnswer: String = "Test",
    nextQuestion: Question? = Fixtures.makeQuestion(id: "q_next", text: "Next question?"),
    sessionPhase: String = "asking",
    explanation: String? = "Because the test says so.",
    audio: AudioInfo? = nil
) -> QuizResponse {
    QuizResponse(
        success: true,
        message: "Input processed",
        session: Fixtures.makeQuizSession(phase: sessionPhase),
        currentQuestion: nextQuestion,
        evaluation: Evaluation(
            userAnswer: userAnswer,
            result: result,
            points: result == .correct ? 1.0 : 0.0,
            correctAnswer: "Expected Answer",
            questionId: "q_001",
            explanation: explanation,
            headlineAnswer: nil
        ),
        feedbackReceived: [],
        audio: audio
    )
}

@MainActor
private func makeDeferredViewModel() -> (QuizViewModel, MockNetworkService) {
    let (vm, network) = Fixtures.makeViewModelWithNetwork()
    vm.settings.answerRevealMode = .endOfSet
    vm.settings.autoRecordEnabled = false // keep the mic out of these tests
    vm.settings.answerTimeLimit = 0 // Off — no lingering answer-timer tasks
    vm.currentSession = Fixtures.makeQuizSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, network)
}

// MARK: - Deferred flow

@Suite("Deferred reveal — no interstitial, immediate advance (#132 E)")
@MainActor
struct DeferredRevealFlowTests {
    /// The core founder decision: submitted answer → next question, with the
    /// result screen never mounted in between.
    @Test("an evaluated answer advances straight to the next question")
    func answerAdvancesWithoutResultScreen() async throws {
        let (vm, _) = makeDeferredViewModel()
        vm.quizState = .processing

        await vm.handleQuizResponse(makeResponse(result: .correct))

        await waitUntil({ vm.quizState == .askingQuestion }, "never advanced to the next question")
        #expect(vm.currentQuestion?.id == "q_next")
        #expect(!vm.quizState.isShowingResult)
    }

    /// A skip is part of the set flow too — neutral entry, same immediate advance.
    @Test("a skip records a neutral entry and advances")
    func skipRecordsNeutralEntryAndAdvances() async throws {
        let (vm, _) = makeDeferredViewModel()
        vm.quizState = .skipping

        await vm.handleQuizResponse(makeResponse(result: .skipped, userAnswer: ""))

        await waitUntil({ vm.quizState == .askingQuestion }, "never advanced after the skip")
        #expect(vm.recapEntries.count == 1)
        #expect(vm.recapEntries[0].wasSkipped)
        #expect(vm.recapEntries[0].userAnswerDisplay == nil, "a skip said nothing (#131 D)")
    }

    /// Last question: the evaluation lands directly on the recap —
    /// `.processing → .finished` with no result screen (the new edge).
    @Test("the last answer finishes the quiz directly")
    func lastAnswerFinishesDirectly() async throws {
        let (vm, _) = makeDeferredViewModel()
        vm.quizState = .processing

        await vm.handleQuizResponse(makeResponse(
            result: .incorrect,
            nextQuestion: nil,
            sessionPhase: "finished"
        ))

        await waitUntil({ vm.quizState == .finished }, "never reached .finished")
        #expect(vm.recapEntries.count == 1)
    }

    /// No audible interstitial either: the response's feedback audio (the
    /// spoken verdict) must never play in deferred mode — it gives the answer
    /// away before the recap.
    @Test("the spoken verdict is suppressed in deferred mode")
    func feedbackAudioSuppressed() async throws {
        let (vm, _) = makeDeferredViewModel()
        vm.quizState = .processing
        let audio = AudioInfo(
            feedbackUrl: nil,
            feedbackAudioBase64: Data("verdict".utf8).base64EncodedString(),
            questionUrl: nil,
            format: "opus"
        )

        await vm.handleQuizResponse(makeResponse(result: .correct, audio: audio))
        await waitUntil { vm.quizState == .askingQuestion }

        let mockAudio = vm.audioService as! MockAudioService
        #expect(mockAudio.playOpusCallCount == 0, "the verdict was spoken — an audible interstitial")
    }

    /// Entries accumulate across the whole set, numbered 1-based in order.
    @Test("entries accumulate in order across the set")
    func entriesAccumulateInOrder() async throws {
        let (vm, _) = makeDeferredViewModel()

        vm.quizState = .processing
        await vm.handleQuizResponse(makeResponse(result: .correct))
        await waitUntil { vm.quizState == .askingQuestion }

        vm.quizState = .skipping
        await vm.handleQuizResponse(makeResponse(result: .skipped, userAnswer: ""))
        await waitUntil { vm.recapEntries.count == 2 }

        #expect(vm.recapEntries.map(\.id) == [1, 2])
        #expect(vm.recapEntries[0].isCorrect)
        #expect(vm.recapEntries[1].wasSkipped)
    }
}

// MARK: - Per-question mode regression

@Suite("Per-question mode is unchanged by #132 E")
@MainActor
struct PerQuestionModeRegressionTests {
    /// The default flow must still mount the result screen — the deferred
    /// branch may only fire on the explicit opt-in.
    @Test("default mode still shows the result screen")
    func defaultModeShowsResult() async throws {
        let (vm, _) = Fixtures.makeViewModelWithNetwork()
        vm.settings.autoAdvanceDelay = 5
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .processing

        await vm.handleQuizResponse(makeResponse(result: .correct))

        #expect(vm.quizState.isShowingResult, "per-question mode must keep today's result screen")
        // The recap ledger still records (a mid-set flip to deferred must
        // yield a full recap).
        #expect(vm.recapEntries.count == 1)
        vm.taskBag.cancelAll() // don't leak the auto-advance task into other suites
    }

    /// The latent Play-Again bug this feature would have inherited: the
    /// completion tallies (and now the recap ledger) must reset when a new
    /// quiz starts WITHOUT passing through resetState (.finished → Play Again).
    @Test("a new quiz starts with a fresh ledger and fresh tallies")
    func playAgainClearsLedger() async throws {
        let (vm, _) = makeDeferredViewModel()
        vm.quizState = .processing
        await vm.handleQuizResponse(makeResponse(result: .correct))
        await waitUntil { vm.recapEntries.count == 1 }
        vm.quizState = .finished

        await vm.startNewQuiz()

        #expect(vm.recapEntries.isEmpty, "recap ledger leaked into the next set")
        #expect(vm.sessionCorrectCount == 0, "completion tallies leaked into the next set")
        vm.taskBag.cancelAll()
    }
}

// MARK: - Narration

@Suite("Recap narration (#132 E)")
@MainActor
struct RecapNarrationTests {
    private func entry(
        number: Int,
        result: Evaluation.EvaluationResult,
        explanation: String? = nil
    ) -> RecapEntry {
        RecapEntry(
            number: number,
            question: Fixtures.makeQuestion(),
            evaluation: Evaluation(
                userAnswer: result == .skipped ? "" : "Said",
                result: result,
                points: 0,
                correctAnswer: "Expected Answer",
                questionId: "q_001",
                explanation: explanation,
                headlineAnswer: nil
            )
        )
    }

    /// Score first, then one line per question (verdict + revealed answer),
    /// then its explanation as its own chunk.
    @Test("chunks: intro, per-question verdict lines, explanations")
    func chunkComposition() {
        let chunks = QuizViewModel.narrationChunks(for: [
            entry(number: 1, result: .correct, explanation: "Because."),
            entry(number: 2, result: .incorrect),
            entry(number: 3, result: .skipped),
        ])

        #expect(chunks.count == 5)
        #expect(chunks[0].contains("1") && chunks[0].contains("3"), "intro carries score 1/3")
        #expect(chunks[1].contains("Expected Answer"))
        #expect(chunks[2] == "Because.")
        #expect(chunks[3].contains("Expected Answer"))
        #expect(chunks[4].contains("Expected Answer"))
    }

    /// The server rejects >1000-char text; long explanations split at
    /// sentence boundaries, never dropped.
    @Test("splitForTTS honors the server cap and loses no text")
    func splitHonorsCap() {
        let sentence = String(repeating: "x", count: 300) + "."
        let long = Array(repeating: sentence, count: 5).joined(separator: " ")

        let chunks = QuizViewModel.splitForTTS(long)

        #expect(chunks.allSatisfy { $0.count <= QuizViewModel.recapTTSChunkLimit })
        let rejoined = chunks.joined(separator: ". ")
        #expect(rejoined.filter { $0 == "x" }.count == long.filter { $0 == "x" }.count)
    }

    /// Playback pipeline: every chunk goes through the generic TTS endpoint.
    @Test("playRecapSummary synthesizes every chunk in order")
    func playSummarySynthesizesChunks() async throws {
        let (vm, network) = makeDeferredViewModel()
        vm.quizState = .processing
        await vm.handleQuizResponse(makeResponse(result: .correct, nextQuestion: nil, sessionPhase: "finished"))
        await waitUntil { vm.quizState == .finished }
        let expected = vm.recapNarrationChunks()

        vm.playRecapSummary()

        await waitUntil({ network.synthesizedTexts.count == expected.count }, "not all chunks were synthesized")
        #expect(network.synthesizedTexts == expected)
        await waitUntil({ !vm.isNarratingRecap }, "narration flag never cleared")
    }

    /// Mute wins everywhere TTS starts (#85) — including the recap, and
    /// including the hands-free auto-read.
    @Test("muted or hands-on: no auto-narration")
    func muteAndHandsOnGates() async throws {
        let (vm, network) = makeDeferredViewModel()
        vm.quizState = .processing
        await vm.handleQuizResponse(makeResponse(result: .correct, nextQuestion: nil, sessionPhase: "finished"))
        await waitUntil { vm.quizState == .finished }

        vm.settings.isMuted = true
        vm.playRecapSummary()
        vm.settings.isMuted = false
        vm.settings.autoRecordEnabled = false
        vm.autoPlayRecapIfHandsFree()

        // Give any wrongly-started narration a chance to surface.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(network.synthesizedTexts.isEmpty, "narration started despite mute / hands-on mode")
    }

    /// The hands-free path (autoRecord ON) auto-reads the recap on appear.
    @Test("hands-free mode auto-reads the recap")
    func handsFreeAutoReads() async throws {
        let (vm, network) = makeDeferredViewModel()
        vm.quizState = .processing
        await vm.handleQuizResponse(makeResponse(result: .correct, nextQuestion: nil, sessionPhase: "finished"))
        await waitUntil { vm.quizState == .finished }
        vm.settings.autoRecordEnabled = true

        vm.autoPlayRecapIfHandsFree()

        await waitUntil({ !network.synthesizedTexts.isEmpty }, "hands-free recap never spoke")
    }
}
