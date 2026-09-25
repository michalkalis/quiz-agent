//
//  AttemptOwnershipTests.swift
//  HangsTests
//
//  #186 step 1 — every async result is bound to the question attempt that
//  started it. Car test 2026-09-23 (#185 finding 1): the guards compared only
//  the phase label (`== .processing` is true for every question), so a late
//  result from question N passed them during question N+1 — a late 400 opened
//  an empty confirmation sheet on the next question. These tests pin the
//  ownership check at the write-backs, the black box that makes a stale drop
//  visible after the fact, and the invariants that name the broken states.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

/// One-shot async gate: holds a mocked upload in flight deterministically.
private actor UploadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Let a just-resumed completion run its (dropping) tail before asserting.
@MainActor
private func drainHops() async {
    for _ in 0 ..< 30 {
        await Task.yield()
    }
}

@Suite("#186 attempt ownership")
@MainActor
struct AttemptOwnershipTests {
    /// A voice upload for question 1, parked inside the network call.
    private func makeUploadInFlight(
        failingWith error: Error? = nil
    ) async -> (QuizViewModel, MockNetworkService, UploadGate, Task<Void, Never>) {
        // A TestClock nobody advances: the gate, not a duration, decides when
        // the upload returns, and the 30 s submit bound never fires under it.
        let (vm, network) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        network.submitVoiceAnswerError = error

        let gate = UploadGate()
        network.submitVoiceAnswerGate = { await gate.wait() }
        let submit = Task { await vm.recordingCoordinator.submitVoiceAnswer(audioData: Data([0x1, 0x2])) }
        await pumpUntil({ network.submitVoiceAnswerCallCount == 1 }, "the upload never reached the network")
        return (vm, network, gate, submit)
    }

    /// Question 1 is left behind with its upload still in flight — the car-test
    /// shape: the question moved on while the backend was still answering.
    private func moveToQuestionTwo(_ vm: QuizViewModel) {
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_002", text: "Next question?")
        vm.quizState = .askingQuestion
    }

    /// WHY (#185 finding 1, the pinning test the issue asks for): a 400 means
    /// "question 1's answer was not understood". Landing on question 2 it used
    /// to take the legal `askingQuestion → processing` edge and open an empty
    /// sheet there — the driver then answered question 1 again, on question 2.
    @Test("a late 400 from question 1 never opens a sheet on question 2")
    func late400FromPreviousQuestionIsDropped() async {
        let (vm, network, gate, submit) = await makeUploadInFlight(
            failingWith: NetworkError.serverError(statusCode: 400, message: "speech not understood")
        )
        moveToQuestionTwo(vm)

        await gate.open()
        await submit.value
        await drainHops()

        #expect(vm.quizState == .askingQuestion, "question 2 stays open for its own answer")
        #expect(vm.showAnswerConfirmation == false)
        #expect(vm.noAnswerCaptured == false)
        #expect(network.synthesizedTexts.isEmpty, "nothing may be said about an answer to a question that is gone")
        #expect(network.submitTextInputCallCount == 0, "and question 2 must not be skipped on its behalf")
        #expect(vm.attemptLedger.droppedPaths.contains("transcriptionFailure"), "the drop is reported, not silent")
    }

    /// WHY: the success twin of the 400 — question 1's transcript must never
    /// become question 2's confirmable answer, with a countdown to grade it.
    @Test("a late transcript from question 1 is dropped on question 2")
    func lateTranscriptFromPreviousQuestionIsDropped() async {
        let (vm, _, gate, submit) = await makeUploadInFlight()
        moveToQuestionTwo(vm)
        // Even `.processing` of question 2 is not question 1's to write into —
        // the phase label alone could not tell the two apart.
        vm.quizState = .processing

        await gate.open()
        await submit.value
        await drainHops()

        #expect(vm.showAnswerConfirmation == false)
        #expect(vm.recordingCoordinator.pendingResponse == nil)
        #expect(vm.transcribedAnswer.isEmpty)
        #expect(vm.taskBag.contains(.autoConfirm) == false)
        #expect(vm.attemptLedger.droppedPaths.contains("voiceSubmit.result"))
    }

    /// WHY: a countdown is an async result too. One armed for an earlier
    /// attempt (a sheet the driver already left) must never confirm into the
    /// attempt that replaced it.
    @Test("an auto-confirm countdown armed for an earlier attempt never fires")
    func staleAutoConfirmNeverFires() async {
        let clock = TestClock()
        let (vm, network) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(clock))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing
        vm.quizMuteOverride = true // no read-back: the countdown arms once the mic is live (#185 5.2)
        vm.recordingCoordinator.presentVoiceTranscript("Paris")
        await pumpUntil({ vm.taskBag.contains(.autoConfirm) }, "the countdown never armed")

        // A new attempt starts without anything cancelling that countdown.
        vm.attemptLedger.begin("test.newAttempt")
        await clock.advance(by: .seconds(Config.autoConfirmDelaySecs + 1))
        await drainHops()

        #expect(network.submitTextInputCallCount == 0, "the stale countdown submitted an answer")
        #expect(vm.quizState == .processing)
    }

    /// WHY: the question read-out's tail arms the countdown that opens the mic.
    /// A read that belonged to question 1 must not arm it on question 2 — the
    /// mic would open during question 2's read-out (#185 finding 1: 0.86 s
    /// after the silent skip). The audio URL cannot tell them apart: it is
    /// session-scoped and identical across questions.
    @Test("question 1's read-out tail arms no countdown on question 2")
    func staleReadOutTailArmsNothing() async {
        let (vm, audio) = Fixtures.makeViewModelWithAudio(clock: AnyClock(TestClock()))
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        audio.playbackDurationNs = 0
        audio.onPlaybackStarted = { [weak vm] in
            // Question 1 is answered and the quiz moves on mid-read.
            vm?.currentQuestion = Fixtures.makeQuestion(id: "q_002")
        }

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.com/q.mp3")

        #expect(vm.taskBag.contains(.thinkingTime) == false, "a countdown for question 2 was armed by question 1's read")
        #expect(vm.taskBag.contains(.answerTimer) == false)
        #expect(vm.attemptLedger.droppedPaths.contains("questionReadOut.tail"))
    }

    /// WHY: a rejected transition is a bug signal. OSLog cannot be read off a
    /// field device, so it must reach the black box (and Sentry) with the
    /// caller that attempted it.
    @Test("a rejected transition is recorded in the flight recorder")
    func rejectedTransitionIsRecorded() {
        let vm = Fixtures.makeViewModel()
        let caller = "test-\(UUID().uuidString)"

        #expect(vm.transition(to: .recording, caller: caller) == false, "idle → recording is not a legal edge")

        let entries = QuizFlightRecorder.shared.entries.filter { $0.detail == caller }
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .reject)
        #expect(entries.first?.name == "idle→recording")
    }

    /// WHY: the invariants are the executable form of "the sheet belongs to
    /// the question on screen". A sheet outside `.processing` is exactly the
    /// car-test state and must be reported, not rendered in silence.
    @Test("a confirmation sheet outside .processing is an invariant violation")
    func sheetOutsideProcessingIsReported() {
        let vm = Fixtures.makeViewModel()
        vm.quizState = .askingQuestion
        vm.showAnswerConfirmation = true

        vm.verifyQuizInvariants(after: "test")

        #expect(vm.attemptLedger.invariantViolations == ["confirmation sheet only in .processing"])
    }

    /// WHY: the other half — a sheet opened for an attempt that is no longer
    /// current is a late result that slipped through a missing owner check.
    @Test("a sheet owned by an earlier attempt is an invariant violation")
    func sheetOfEarlierAttemptIsReported() {
        let vm = Fixtures.makeViewModel()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        let stale = vm.currentAttempt
        vm.attemptLedger.begin("test.newAttempt")
        vm.quizState = .processing
        vm.quizMuteOverride = true

        vm.recordingCoordinator.presentVoiceTranscript("Paris", owner: stale)

        #expect(vm.attemptLedger.invariantViolations == ["confirmation sheet belongs to the current attempt"])
    }

    /// WHY (RS-09 on CI, 2026-09-24): once a recording's forced commit has put
    /// its transcript on the sheet, a committed transcript arriving LATER on
    /// the same stream must never replace it — the sheet would otherwise show
    /// (and grade) an answer the driver never confirmed.
    @Test("a committed transcript arriving after the recording ended never replaces the sheet's transcript")
    func lateCommittedTranscriptNeverReplacesSheet() async {
        let stt = MockElevenLabsSTTService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            sttService: stt,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.quizMuteOverride = true

        await vm.recordingCoordinator.startRecording()
        await pumpUntil({ vm.isStreamingSTT }, "streaming never started")
        await vm.recordingCoordinator.stopRecordingAndSubmit(reason: .noSpeechWindow) // forced commit → "Paris"
        await pumpUntil({ vm.showAnswerConfirmation }, "the forced commit never reached the sheet")
        #expect(vm.transcribedAnswer == "Paris")

        await stt.injectEvent(.committedTranscript("Jupiter"))
        await drainHops()

        #expect(vm.transcribedAnswer == "Paris", "a late transcript replaced the one on the sheet")
        #expect(vm.quizState == .processing)
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY: the ownership checks must not cost the normal flow anything — a
    /// full voice answer (record → upload → sheet → confirm → result) drops no
    /// result and breaks no invariant, or the checks are wrong.
    @Test("a normal voice answer drops nothing and breaks no invariant")
    func normalFlowIsClean() async {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        vm.quizMuteOverride = true

        await vm.toggleRecording()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
        #expect(vm.showAnswerConfirmation)
        #expect(vm.recordingCoordinator.confirmationOwner == vm.currentAttempt)

        await vm.confirmAnswer()

        #expect(vm.quizState.isShowingResult)
        #expect(vm.attemptLedger.droppedPaths.isEmpty)
        #expect(vm.attemptLedger.invariantViolations.isEmpty)
    }
}

// MARK: - Flight recorder

@Suite("#186 quiz flight recorder")
struct QuizFlightRecorderTests {
    /// WHY: the black box is bounded — a long drive must not grow memory, and
    /// the NEWEST events are the ones that explain the broken screen.
    @Test("keeps only the newest events up to its capacity")
    func ringKeepsNewest() {
        let recorder = QuizFlightRecorder(capacity: 3)
        for index in 1 ... 5 {
            recorder.record(.tap, "tap\(index)", attempt: "q#\(index)", state: "askingQuestion")
        }

        #expect(recorder.entries.map(\.name) == ["tap3", "tap4", "tap5"])
    }

    /// WHY: the dump is what Sentry events and feedback reports carry — it must
    /// name the input, the attempt and the state of every event.
    @Test("the dump and the tail name kind, event, attempt and state")
    func dumpNamesEverything() {
        let recorder = QuizFlightRecorder(capacity: 10)
        recorder.record(.network, "voiceSubmit.400", attempt: "q_001#4", state: "processing")
        recorder.record(.drop, "transcriptionFailure", attempt: "q_002#5", state: "askingQuestion", detail: "owner=q_001#4")

        let dump = recorder.dump()
        #expect(dump.contains("network voiceSubmit.400 attempt=q_001#4 state=processing"))
        #expect(dump.contains("drop transcriptionFailure attempt=q_002#5 state=askingQuestion owner=q_001#4"))
        #expect(recorder.tail(1) == "drop:transcriptionFailure@q_002#5/askingQuestion")
    }
}
