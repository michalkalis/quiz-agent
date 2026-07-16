//
//  QuizViewModelSubmissionRaceTests.swift
//  HangsTests
//
//  Issue #79: a TYPED answer submitted while a committed-voice-transcript handler
//  is suspended mid-flight (inside its STT disconnect) must NOT (a) fire a second
//  concurrent backend submission, nor (b) resurrect the voice confirmation sheet
//  with the stale voice transcript. The fix is a single-flight submission epoch
//  owned by QuizViewModel: every submit path bumps it before its first await, and
//  handleCommittedTranscript aborts if the epoch moved while it was suspended.
//
//  Uses withMainSerialExecutor (ConcurrencyExtras) for deterministic scheduling.
//  The MockElevenLabsSTTService.disconnect() gate parks the committed-transcript
//  handler so the typed submission can interleave exactly at the race window.
//

import Foundation
import Testing
import ConcurrencyExtras
@testable import Hangs

// MARK: - Helpers

/// ViewModel + mocks wired for streaming STT, seeded at .askingQuestion.
@MainActor
private func makeViewModelWithSTT()
    -> (QuizViewModel, MockNetworkService, MockAudioService, MockElevenLabsSTTService) {
    let mockNetwork = Fixtures.makeFullMockNetwork()
    let mockAudio = MockAudioService()
    let mockPersistence = MockPersistenceStore()
    let mockSTT = MockElevenLabsSTTService()

    let viewModel = QuizViewModel(
        networkService: mockNetwork,
        audioService: mockAudio,
        persistenceStore: mockPersistence,
        silenceDetectionService: nil,
        sttService: mockSTT
    )
    viewModel.currentSession = Fixtures.makeActiveSession()
    viewModel.currentQuestion = Fixtures.makeQuestion()
    viewModel.quizState = .askingQuestion
    return (viewModel, mockNetwork, mockAudio, mockSTT)
}

/// A 4-option MCQ where "Jupiter" is an unambiguous value match (key "b").
@MainActor
private func makeMCQQuestion() -> Question {
    Question(
        id: "q_mcq_001",
        question: "Largest planet?",
        type: .textMultichoice,
        possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Venus", "d": "Saturn"],
        difficulty: "medium",
        topic: "Astronomy",
        category: "science",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )
}

/// Spin until `predicate` is true (sync @MainActor state). See the twin in
/// QuizViewModelStreamingTests for the wall-clock / real-sleep rationale.
@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 10_000,
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

/// Async variant: the disconnect-gate flag lives on the STT actor, so the
/// predicate must be able to `await` across the actor boundary.
@MainActor
private func waitUntilAsync(
    _ predicate: () async -> Bool,
    timeoutMillis: Int = 10_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if await predicate() { return }
    Issue.record(comment ?? "waitUntilAsync timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

/// Let a just-resumed handler run its (aborting) tail before we assert.
@MainActor
private func drainHops() async {
    for _ in 0 ..< 20 { await Task.yield() }
}

// MARK: - Suite

@Suite("QuizViewModel Submission Race Tests (#79)")
@MainActor
struct QuizViewModelSubmissionRaceTests {

    // MARK: - (a) Free-text race

    /// #79 acceptance: a typed answer submitted while the committed free-text
    /// transcript handler is parked in disconnect() must win — exactly one submit
    /// (the typed one), sheet stays dismissed, and the stale voice text never
    /// clobbers transcribedAnswer.
    @Test("typed answer during a suspended free-text commit yields one submit and no stale sheet")
    func typedAnswerWinsFreeTextRace() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            // Park the committed-transcript handler inside disconnect().
            await mockSTT.setGateDisconnect(true)
            await mockSTT.injectEvent(.committedTranscript("Paris")) // voice
            await waitUntilAsync({ await mockSTT.isSuspendedInDisconnect }, "handler never reached disconnect gate")

            // Typed answer races in mid-teardown (the #79 window).
            await viewModel.resubmitAnswer("London") // typed
            #expect(viewModel.quizState.isShowingResult)

            // Resume the parked handler — it must detect the moved epoch and bail.
            await mockSTT.releaseDisconnect()
            await waitUntilAsync({ await !mockSTT.isSuspendedInDisconnect }, "handler never resumed")
            await drainHops()

            #expect(mockNetwork.submitTextInputCallCount == 1)
            #expect(mockNetwork.capturedTextInputInput == "London")
            #expect(viewModel.showAnswerConfirmation == false)
            #expect(viewModel.transcribedAnswer != "Paris")
        }
    }

    // MARK: - (b) MCQ race

    /// #79 acceptance: same interleaving on an MCQ question — the typed submit wins
    /// and the voice MCQ submit (submitMCQAnswer, past the disconnect gate) is
    /// aborted, so still exactly one backend submission.
    @Test("typed answer during a suspended MCQ commit aborts the voice MCQ submit")
    func typedAnswerWinsMCQRace() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()
            viewModel.currentQuestion = makeMCQQuestion()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.setGateDisconnect(true)
            await mockSTT.injectEvent(.committedTranscript("Jupiter")) // voice MCQ match
            await waitUntilAsync({ await mockSTT.isSuspendedInDisconnect }, "handler never reached disconnect gate")

            await viewModel.resubmitAnswer("London") // typed
            #expect(viewModel.quizState.isShowingResult)

            await mockSTT.releaseDisconnect()
            await waitUntilAsync({ await !mockSTT.isSuspendedInDisconnect }, "handler never resumed")
            await drainHops()

            #expect(mockNetwork.submitTextInputCallCount == 1)
            #expect(mockNetwork.capturedTextInputInput == "London")
            // The MCQ branch (which sets the highlight key) must never be reached.
            #expect(viewModel.mcqVoiceMatchedKey == nil)
        }
    }

    // MARK: - (c) Sheet-dismiss

    /// #79 acceptance: when the voice confirmation sheet is already up (commit
    /// fully processed), a typed answer dismisses it and submits exactly once.
    @Test("typed answer while the confirmation sheet is up dismisses it and submits once")
    func typedAnswerDismissesConfirmationSheet() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.committedTranscript("Paris")) // no gate → sheet appears
            await waitUntil({ viewModel.showAnswerConfirmation }, "confirmation sheet never appeared")
            #expect(mockNetwork.submitTextInputCallCount == 0) // sheet only, nothing submitted yet

            await viewModel.resubmitAnswer("London") // typed
            await waitUntil({ viewModel.quizState.isShowingResult }, "typed submit never completed")

            #expect(viewModel.showAnswerConfirmation == false)
            #expect(mockNetwork.submitTextInputCallCount == 1)
            #expect(mockNetwork.capturedTextInputInput == "London")
        }
    }

    // MARK: - (d) Normal voice flow unaffected

    /// #79 regression guard: with NO typed interference the epoch never moves, so
    /// the committed transcript still surfaces the sheet with the voice text and
    /// submits nothing until the user confirms — exactly as before the fix.
    @Test("committed transcript with no typed interference shows the sheet with the voice text")
    func normalVoiceFlowUnaffected() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()

            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")

            await mockSTT.injectEvent(.committedTranscript("Paris"))
            await waitUntil({ viewModel.quizState == .processing }, "never reached .processing")

            #expect(viewModel.transcribedAnswer == "Paris")
            #expect(viewModel.showAnswerConfirmation == true)
            #expect(viewModel.isStreamingSTT == false)
            #expect(mockNetwork.submitTextInputCallCount == 0)
        }
    }

    // MARK: - (e) confirmAnswer() double-submit (#100.2)

    /// #100.2 regression guard: auto-confirm timer and a tap both calling
    /// confirmAnswer() at the same instant must still yield exactly one submit.
    /// #79's isSubmittingAnswer single-flight flag already closes true
    /// simultaneity — this should already pass — but it's the sibling case to
    /// (f) below and worth pinning down explicitly.
    @Test("two concurrent confirmAnswer calls (auto-confirm + tap) yield exactly one submit")
    func doubleConfirmAnswerYieldsOneSubmit() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()
            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")
            await mockSTT.injectEvent(.committedTranscript("Paris"))
            await waitUntil({ viewModel.showAnswerConfirmation }, "confirmation sheet never appeared")

            async let first: Void = viewModel.confirmAnswer()
            async let second: Void = viewModel.confirmAnswer()
            _ = await (first, second)

            await waitUntil({ viewModel.quizState.isShowingResult }, "submission never completed")
            #expect(mockNetwork.submitTextInputCallCount == 1)
            #expect(mockNetwork.capturedTextInputInput == "Paris")
        }
    }

    /// #100.2 actual regression target: a stray/late confirmAnswer() call
    /// *after* the first has fully resolved (isSubmittingAnswer already reset
    /// via defer) must not resubmit the stale transcribedAnswer against
    /// whatever question/session is now current. Fails on pre-fix code
    /// (transcribedAnswer was never cleared, so the guard at the top of the
    /// streaming-path tail still sees non-empty text and resubmits "Paris" a
    /// second time) — passes once confirmAnswer() captures-then-clears
    /// transcribedAnswer before the await.
    @Test("a stray confirmAnswer after the sheet already resolved does not resubmit the stale transcript")
    func staleConfirmAnswerAfterResolutionDoesNotResubmit() async throws {
        await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, mockSTT) = makeViewModelWithSTT()
            await viewModel.startRecording()
            await waitUntil({ viewModel.isStreamingSTT }, "streaming never started")
            await mockSTT.injectEvent(.committedTranscript("Paris"))
            await waitUntil({ viewModel.showAnswerConfirmation }, "confirmation sheet never appeared")

            // First confirm (e.g. auto-confirm timer) resolves fully.
            await viewModel.confirmAnswer()
            await waitUntil({ viewModel.quizState.isShowingResult }, "first submit never completed")
            #expect(mockNetwork.submitTextInputCallCount == 1)

            // Stray/delayed second call (e.g. a button tap recognized as the sheet
            // dismissed) — must be a no-op now that transcribedAnswer was cleared.
            await viewModel.confirmAnswer()
            await drainHops()

            #expect(mockNetwork.submitTextInputCallCount == 1) // still one, not two
        }
    }

    // MARK: - (g) confirmAnswer() double-submit on the Whisper path (#100.2 follow-up)

    /// Seeds the Whisper (non-streaming) confirmation state exactly as
    /// submitRecordedAnswer leaves it (iOS 18–25, or an iOS 26 STT-init
    /// failure): cached pendingResponse, transcript shown, sheet up.
    private func seedWhisperConfirmation(
        _ viewModel: QuizViewModel, _ mockNetwork: MockNetworkService
    ) throws {
        viewModel.quizState = .processing
        viewModel.pendingResponse = try #require(mockNetwork.mockResponse)
        viewModel.transcribedAnswer = "Paris"
        viewModel.showAnswerConfirmation = true
    }

    /// #100.2 follow-up: on the Whisper path the winner consumes
    /// pendingResponse and suspends in handleQuizResponse; the loser sees
    /// pendingResponse == nil and falls through to the streaming tail. Pre-fix
    /// (clear only in the tail) it still found the stale transcript there and
    /// POSTed it — scored against the next question. Capture-then-clear on
    /// entry makes the loser a no-op: zero /input submissions.
    @Test("Whisper path: concurrent confirmAnswer calls never resubmit the stale transcript")
    func doubleConfirmAnswerOnWhisperPathDoesNotResubmit() async throws {
        try await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, _) = makeViewModelWithSTT()
            try seedWhisperConfirmation(viewModel, mockNetwork)

            async let first: Void = viewModel.confirmAnswer()
            async let second: Void = viewModel.confirmAnswer()
            _ = await (first, second)
            await drainHops()

            await waitUntil({ viewModel.quizState.isShowingResult }, "Whisper response never resolved")
            // The cached Whisper response resolves locally — no /input POST ever.
            #expect(mockNetwork.submitTextInputCallCount == 0)
        }
    }

    /// #100.2 follow-up, stray-late variant: after the Whisper confirm fully
    /// resolved, a delayed confirmAnswer() must not resubmit the transcript
    /// (showingResult → processing is a legal transition, so only the cleared
    /// transcript stops it).
    @Test("Whisper path: a stray confirmAnswer after resolution does not resubmit the stale transcript")
    func staleConfirmAnswerOnWhisperPathDoesNotResubmit() async throws {
        try await withMainSerialExecutor {
            let (viewModel, mockNetwork, _, _) = makeViewModelWithSTT()
            try seedWhisperConfirmation(viewModel, mockNetwork)

            await viewModel.confirmAnswer()
            await waitUntil({ viewModel.quizState.isShowingResult }, "Whisper response never resolved")

            await viewModel.confirmAnswer() // stray/delayed second call
            await drainHops()

            #expect(mockNetwork.submitTextInputCallCount == 0)
        }
    }
}
