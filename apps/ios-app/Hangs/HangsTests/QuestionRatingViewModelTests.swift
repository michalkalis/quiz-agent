//
//  QuestionRatingViewModelTests.swift
//  HangsTests
//
//  #155 in-app rating panel. What these tests encode, and why it matters:
//  - The payload IS the feature: a rating that reaches the #154 store with the
//    wrong question id, a rescaled score or a dropped justification is worse
//    than no rating at all, because the calibration analysis silently trusts it.
//  - A score is required, the justification is not — the panel exists to be
//    used one-handed mid-quiz.
//  - Dictation must stay blocked while the quiz itself holds the mic: one
//    shared AVAudioEngine, and a second one is the #64/#77 crash class.
//  - Rating must never disturb the quiz. The panel is a debug surface bolted on
//    top of a live state machine; if submitting moved that machine, the tool
//    would corrupt the very session it is rating.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeRatingVM(
    questionId: String = "11111111-1111-1111-1111-111111111111",
    service: MockQuestionRatingService = MockQuestionRatingService(),
    quizRecording: Bool = false,
    micGranted: Bool = true,
    stt: MockElevenLabsSTTService? = MockElevenLabsSTTService(),
    audio: MockAudioService = MockAudioService()
) -> (QuestionRatingViewModel, MockQuestionRatingService, MockAudioService) {
    audio.micPermissionResult = micGranted
    let voice = FeedbackVoiceServices(
        audioService: audio,
        sttService: stt,
        isQuizRecording: { quizRecording },
        languageCode: "sk"
    )
    let vm = QuestionRatingViewModel(
        questionId: questionId,
        questionText: "Which planet rotates on its side?",
        ratingService: service,
        networkService: MockNetworkService(),
        voice: voice
    )
    return (vm, service, audio)
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5000,
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

// MARK: - Score + submit

@Suite("QuestionRatingViewModel — score and submit (#155)")
@MainActor
struct QuestionRatingSubmitTests {
    @Test("no score selected means nothing can be submitted")
    func scoreIsRequired() async {
        let (vm, service, _) = makeRatingVM()

        #expect(vm.selectedScore == nil)
        #expect(vm.canSubmit == false)

        // A justification alone is not a rating.
        vm.justification = "felt too easy"
        #expect(vm.canSubmit == false)
        await vm.submit()
        #expect(service.capturedRatings.isEmpty, "submitted without a score")

        vm.select(score: 7)
        #expect(vm.canSubmit == true)
    }

    @Test("selection is exclusive and clamped to the 1–10 scale the store validates")
    func selectionIsExclusiveAndClamped() {
        let (vm, _, _) = makeRatingVM()

        vm.select(score: 3)
        #expect(vm.isSelected(score: 3))

        vm.select(score: 9)
        #expect(vm.isSelected(score: 9))
        #expect(vm.isSelected(score: 3) == false, "two scores selected at once")

        // Out-of-range taps must not silently rewrite the selection — the
        // backend rejects anything outside 1…10.
        vm.select(score: 0)
        vm.select(score: 11)
        #expect(vm.selectedScore == 9)
    }

    @Test("submit posts {question id, score, justification} exactly once")
    func submitSendsThePayload() async {
        let (vm, service, _) = makeRatingVM(questionId: "abc-123")

        vm.select(score: 8)
        vm.justification = "  surprising and checkable  "
        await vm.submit()

        #expect(service.capturedRatings.count == 1)
        let sent = service.capturedRatings.first
        #expect(sent?.questionId == "abc-123")
        #expect(sent?.score == 8)
        // Trimmed — trailing whitespace from dictation must not reach the store.
        #expect(sent?.reason == "surprising and checkable")
        // Identity is the JWT subject server-side; the client sends no name.
        #expect(sent?.displayName == nil)
        #expect(vm.submitState == .saved)

        // A saved panel cannot double-post on a second tap.
        await vm.submit()
        #expect(service.capturedRatings.count == 1)
    }

    @Test("an empty justification is sent as nil, not an empty string")
    func emptyJustificationIsOmitted() async {
        let (vm, service, _) = makeRatingVM()
        vm.select(score: 5)
        vm.justification = "   "
        await vm.submit()

        #expect(service.capturedRatings.first?.reason == nil)
    }

    @Test("a failed submit surfaces inline and keeps the score for a retry")
    func failedSubmitKeepsState() async {
        let service = MockQuestionRatingService(result: .failure(.init("boom")))
        let (vm, _, _) = makeRatingVM(service: service)

        vm.select(score: 4)
        await vm.submit()

        #expect(vm.errorMessage != nil)
        #expect(vm.selectedScore == 4)
        #expect(vm.canSubmit == true, "a failed rating must be retryable")

        // Picking a different score clears the stale error.
        vm.select(score: 6)
        #expect(vm.errorMessage == nil)
    }
}

// MARK: - Dictation guard

@Suite("QuestionRatingViewModel — dictation guard (#155)", .serialized)
@MainActor
struct QuestionRatingDictationTests {
    @Test("mic is blocked and inert while the quiz itself is recording")
    func blockedWhileQuizRecording() async {
        await withMainSerialExecutor {
            let (vm, _, audio) = makeRatingVM(quizRecording: true)

            #expect(vm.isBlockedByQuizRecording == true)
            #expect(vm.micButtonDisabled == true)

            await vm.startDictation()

            // The single shared engine must never open here.
            #expect(vm.micState == .idle)
            #expect(audio.isRecording == false)
            #expect(audio.streamingChunkHandler == nil)
        }
    }

    @Test("denied mic permission degrades to typing, never opens the engine")
    func deniedPermissionDegradesToTyping() async {
        await withMainSerialExecutor {
            let (vm, _, audio) = makeRatingVM(micGranted: false)

            await vm.startDictation()

            #expect(vm.micState == .denied)
            #expect(audio.isRecording == false)
            vm.select(score: 2)
            vm.justification = "typed because mic is off"
            #expect(vm.canSubmit == true)
        }
    }

    @Test("committed segments append to the editable justification")
    func committedSegmentsAppend() async {
        await withMainSerialExecutor {
            let stt = MockElevenLabsSTTService()
            let (vm, _, _) = makeRatingVM(stt: stt)

            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "dictation never started")

            await stt.injectEvent(.partialTranscript("too ea..."))
            await waitUntil({ vm.partialTranscript == "too ea..." }, "partial never propagated")

            await stt.injectEvent(.committedTranscript("too easy"))
            await waitUntil({ vm.justification == "too easy" }, "committed segment never appended")
            #expect(vm.partialTranscript == "")

            await stt.injectEvent(.committedTranscript("for adults"))
            await waitUntil({ vm.justification == "too easy for adults" }, "second segment never appended")
        }
    }

    @Test("with no STT service the panel stays text-only instead of hiding the mic state")
    func noSTTMeansNoVoice() async {
        let (vm, _, audio) = makeRatingVM(stt: nil)
        #expect(vm.voiceAvailable == false)
        await vm.startDictation()
        #expect(vm.micState == .idle)
        #expect(audio.isRecording == false)
    }
}

// MARK: - Quiz isolation

@Suite("QuestionRatingViewModel — the quiz is untouched (#155)")
@MainActor
struct QuestionRatingQuizIsolationTests {
    @Test("submitting a rating triggers no quiz-state transition")
    func submitDoesNotMoveTheStateMachine() async {
        let quiz = Fixtures.makeViewModel()
        quiz.currentSession = Fixtures.makeActiveSession()
        quiz.currentQuestion = Fixtures.makeQuestion()
        quiz.quizState = .askingQuestion
        let answeredBefore = quiz.questionsAnswered

        let service = MockQuestionRatingService()
        let vm = QuestionRatingViewModel(
            questionId: quiz.currentQuestion?.id ?? "",
            ratingService: service,
            networkService: MockNetworkService(),
            voice: FeedbackVoiceServices(
                audioService: MockAudioService(),
                sttService: nil,
                isQuizRecording: { quiz.quizState == .recording },
                languageCode: "en"
            )
        )

        vm.select(score: 10)
        await vm.submit()

        #expect(service.capturedRatings.count == 1)
        #expect(quiz.quizState == .askingQuestion, "rating moved the quiz to \(quiz.quizState)")
        #expect(quiz.questionsAnswered == answeredBefore)
        #expect(quiz.currentQuestion?.id == service.capturedRatings.first?.questionId)
    }
}
