//
//  QuestionScopedSubmitTests.swift
//  HangsTests
//
//  #133 1a. The answer-submit API is now question-scoped: every submit carries
//  the id of the question it answers, and the backend replays (or re-grades)
//  instead of scoring a re-sent answer against the next, unseen question.
//
//  What these tests protect is money and trust, not plumbing. If a submit path
//  sends the WRONG id — the next question's, or none at all — the server falls
//  back to "grade whatever is current": the player is charged a second freemium
//  question and gets a verdict for a question they never saw. That was the
//  reported defect (audit 2026-07-30, findings on TransientRetry + the
//  edited-transcript resubmit), so each path asserts the id equals the question
//  the player was actually looking at.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Question-scoped answer submit (#133 1a)")
@MainActor
struct QuestionScopedSubmitTests {
    /// Seeds an open question `q_001`. The network mock's happy-path response
    /// carries `currentQuestion: q_002` — the NEXT question — so any test that
    /// mistakenly reads the id off the response instead of the on-screen
    /// question fails visibly rather than passing by coincidence.
    private func makeViewModel() -> (QuizViewModel, MockNetworkService) {
        let (vm, network) = Fixtures.makeViewModelWithNetwork()
        vm.transientStartBackoffOverride = { _ in .zero }
        vm.recordingCoordinator.transientBackoffOverride = { _ in .zero }
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return (vm, network)
    }

    // MARK: - Every submit path scopes itself to the on-screen question

    @Test("MCQ tap submits the id of the question on screen")
    func mcqSubmitCarriesCurrentQuestionId() async throws {
        let (vm, network) = makeViewModel()

        await vm.submitMCQAnswer(key: "a", value: "Paris")

        #expect(network.capturedTextInputQuestionId == "q_001")
    }

    @Test("skip submits the id of the question being skipped")
    func skipCarriesCurrentQuestionId() async throws {
        let (vm, network) = makeViewModel()

        await vm.skipQuestion()

        #expect(network.capturedTextInputQuestionId == "q_001")
    }

    @Test("typed answer submits the id of the question on screen")
    func typedAnswerCarriesCurrentQuestionId() async throws {
        let (vm, network) = makeViewModel()

        await vm.resubmitAnswer("Bratislava")

        #expect(network.capturedTextInputQuestionId == "q_001")
    }

    @Test("voice submit carries the id of the question being answered")
    func voiceSubmitCarriesCurrentQuestionId() async throws {
        let (vm, network) = makeViewModel()

        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))

        #expect(network.capturedVoiceAnswerQuestionId == "q_001")
    }

    // MARK: - The edited-transcript path (the reported defect)

    /// The original bug: the user corrects a Whisper transcript, the client
    /// throws away the completed evaluation and re-POSTs the text to a session
    /// the server has ALREADY advanced — so the correction was graded against
    /// the next question and burned a second quota unit.
    ///
    /// Driven through the real reachable order (voice submit → confirmation
    /// sheet → pencil → confirm) rather than by poking state, because the whole
    /// question is *which* question is current at that moment. `currentQuestion`
    /// still holds the answered question here: the advance to the response's
    /// next question happens in `advanceToNextQuestionOrFinish`, never in
    /// `handleQuizResponse`.
    @Test("editing a Whisper transcript re-submits against the ANSWERED question, not the next one")
    func editedTranscriptResubmitsAgainstAnsweredQuestion() async throws {
        let (vm, network) = makeViewModel()

        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))
        #expect(vm.showAnswerConfirmation, "voice submit should land on the confirmation sheet")
        #expect(network.capturedVoiceAnswerQuestionId == "q_001")

        vm.recordingCoordinator.beginEditingTranscript() // discards the cached evaluation
        vm.transcribedAnswer = "Bratislava"
        await vm.recordingCoordinator.confirmAnswer()

        #expect(network.submitTextInputCallCount == 1, "the correction is re-sent exactly once")
        #expect(network.capturedTextInputInput == "Bratislava")
        #expect(
            network.capturedTextInputQuestionId == "q_001",
            "the edit re-grades the question the player saw — sending q_002 would grade an unseen question and charge again"
        )
    }

    // MARK: - 409 question_mismatch

    /// A 409 proves the request reached application code and that the server
    /// graded nothing. So: surface it, do NOT retry it (a retry re-sends the
    /// same stale id and fails identically), and leave the quiz state untouched
    /// — no advance, no score, no recap row.
    @Test("a question_mismatch 409 on a text submit surfaces once, without retry or state damage")
    func textSubmitMismatchSurfacesWithoutRetry() async throws {
        let (vm, network) = makeViewModel()
        network.submitTextInputError = NetworkError.questionMismatch(currentQuestionId: "q_042")

        await vm.resubmitAnswer("Bratislava")

        #expect(network.submitTextInputCallCount == 1, "a 409 must never be retried")
        if case .error = vm.quizState {} else {
            Issue.record("a question_mismatch must reach the user, got \(vm.quizState.label)")
        }
        #expect(vm.activeErrorModel?.retryAction == .goHome, "retrying the same stale id cannot work — recovery is a new session")
        #expect(vm.currentQuestion?.id == "q_001", "the rejected submit must not advance the question")
        #expect(vm.recapEntries.isEmpty, "nothing was graded, so nothing may be recorded")
        #expect(vm.sessionCorrectCount == 0)
    }

    /// The voice catch-chain special-cases a 400 as "speech not understood →
    /// let the user re-record". A 409 must not be swallowed by that branch: the
    /// recording was fine, the client is out of step.
    @Test("a question_mismatch 409 on a voice submit surfaces as an error, not a re-record prompt")
    func voiceSubmitMismatchSurfacesAsError() async throws {
        let (vm, network) = makeViewModel()
        network.submitVoiceAnswerError = NetworkError.questionMismatch(currentQuestionId: "q_042")

        await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2]))

        #expect(network.submitVoiceAnswerCallCount == 1, "a 409 must never be retried")
        if case .error = vm.quizState {} else {
            Issue.record("a question_mismatch must reach the user, got \(vm.quizState.label)")
        }
        #expect(vm.showAnswerConfirmation == false)
        #expect(vm.activeErrorModel?.retryAction == .goHome)
    }
}
