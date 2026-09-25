//
//  QuizSequenceRun.swift
//  HangsTests
//
//  #186 step 2 — one sequence against the REAL `QuizViewModel`: the batch
//  answer path (#184 default), the shared silence-detector / persistence /
//  earcon mocks, the scripted network and audio, and one test clock for every
//  wait the quiz makes — timers, backoffs, the hardware settles and the length
//  of each clip. Everything runs on the process-wide main serial executor, so
//  the same inputs at the same times interleave the same way on every run.
//
//  An input is applied the way the app delivers it: a UI tap as the view's
//  action (async ones in a fire-and-forget `Task`, like SwiftUI), a spoken
//  command through the recognised-command router, speech through the VAD
//  stream, a server answer by resuming the parked request. An input whose
//  control is not on screen (or whose request is not in flight) is inert —
//  the same rule during generation, replay and shrinking.
//

import Clocks
import Combine
import Foundation
@testable import Hangs
import SwiftUI

@MainActor
final class QuizSequenceRun {
    struct Violation: Equatable {
        /// Stable across shrinking — the invariant, never a counter or an id.
        let invariant: String
        let detail: String
        let atMs: Int
    }

    struct Applied {
        let timed: TimedInput
        let attempt: String
        let state: String
        let applied: Bool
    }

    let config: QuizSequenceConfig
    let clock = SequenceClock()
    let network: SequenceNetwork
    let audio: SequenceAudio
    let silence = MockSilenceDetectionService()
    let recorder = QuizFlightRecorder(capacity: 5000)
    let vm: QuizViewModel

    var violation: Violation?
    private(set) var log: [Applied] = []
    /// Every confirmation sheet seen, as "<question> <transcript>".
    var sheetsSeen: [String] = []
    /// Every skip the driver asked for that reached the server.
    var skipsSubmitted: [String] = []

    /// A burst (or a woken timer) has settled once nothing observable moved for
    /// `quietTurns` scheduler turns in a row, or after `maxTurns`. Every wait is
    /// on the test clock or a parked call, so this only bounds how far a chain
    /// runs before the next input — never whether the run is repeatable.
    static let quietTurns = 5
    static let maxTurns = 40

    private(set) var nowMs = 0
    /// The input whose effects are running; `nil` while time passes.
    var context: QuizInput?
    var burstHasDriver = false
    private var tasks: [Task<Void, Never>] = []
    private var cancellables: Set<AnyCancellable> = []
    var lastState: QuizState = .idle
    var seenLedgerViolations = 0
    var seenRecapEntries = 0
    /// Skips the driver asked for, per question, not yet sent.
    var skipIntents: [String: Int] = [:]
    /// The attempt of the last skip sent per question — its transient-retry
    /// re-sends are the same skip, not a new one.
    var sentSkips: [String: AttemptID] = [:]
    private var typedAnswers = 0
    /// Transient conditions seen at the last check → since when (ms).
    var episodes: [String: Int] = [:]
    /// The black box up to the moment of the violation — what the report
    /// prints (the teardown after it is not part of the story).
    var recorderAtViolation: String?

    init(config: QuizSequenceConfig) {
        self.config = config
        let anyClock = AnyClock(clock)
        network = SequenceNetwork(config: config)
        audio = SequenceAudio(clock: anyClock)

        let store = MockPersistenceStore()
        var settings = QuizSettings.default
        settings.numberOfQuestions = config.questionCount
        settings.autoRecordEnabled = config.autoRecord
        settings.thinkingTime = config.thinkingTime
        settings.autoConfirmEnabled = config.autoConfirm
        settings.isMuted = config.muted
        settings.voiceCommandsEnabled = config.voiceCommands
        settings.answerRevealMode = config.endOfSetReveal ? .endOfSet : .perQuestion
        store.savedSettings = settings
        // #185 track A: a detector that cannot vouch for silence hands the 5 s
        // window's decision to the dead-air cap (the car-test device).
        silence.noSpeechWindowVerdict = config.deafDetector ? .noAudio : .quiet
        audio.questionClipsEndOnCue = config.readOutEndsFromDump

        vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: store,
            silenceDetectionService: silence,
            sttService: nil,
            clock: anyClock,
            flightRecorder: recorder
        )
        vm.settleClock = anyClock
        vm.earconPlayer = MockEarconPlayer()
        clock.settle = { [weak self] in await self?.drain() }

        network.attemptProbe = { [weak vm] in vm?.currentAttempt ?? .none }
        network.onTextSubmit = { [weak self] in self?.textSubmitted($0) }
        audio.onCutShort = { [weak self] in self?.clipCutShort($0, $1, question: $2) }
        lastState = vm.quizState
        vm.$quizState.dropFirst()
            .sink { [weak self] in self?.stateWillChange(to: $0) }
            .store(in: &cancellables)
    }

    // MARK: - Driving

    /// Home → "Start": the quiz start every sequence begins from.
    func start() async {
        vm.beginQuizStart()
        await drain()
        check()
    }

    /// Let the running burst finish, then move the clock to `ms`.
    func advance(to ms: Int) async {
        guard ms > nowMs, violation == nil else { return }
        await drain()
        check()
        guard violation == nil else { return }
        context = nil
        burstHasDriver = false
        await clock.advance(by: .milliseconds(ms - nowMs))
        nowMs = ms
        check()
    }

    func apply(_ timed: TimedInput) {
        guard violation == nil else { return }
        context = timed.input
        if timed.input.isDriver { burstHasDriver = true }
        let attempt = vm.currentAttempt.description
        let state = vm.quizState.label
        let applied = perform(timed)
        log.append(Applied(timed: timed, attempt: attempt, state: state, applied: applied))
    }

    /// Stop giving input and let 45 s pass in 5 s steps — past the longest
    /// bound below (the 35 s stall watchdog): every state the quiz cannot rest
    /// in must have ended by itself.
    func finish() async {
        await drain()
        check()
        context = nil
        burstHasDriver = false
        for _ in 0 ..< 9 where violation == nil {
            await clock.advance(by: .seconds(5))
            nowMs += 5000
            check()
        }
        await teardown()
    }

    private func teardown() async {
        cancellables.removeAll()
        tasks.forEach { $0.cancel() }
        vm.taskBag.cancelAll()
        network.failAll()
        audio.teardown()
        await drain()
    }

    /// Yield until nothing observable moved for `quietTurns` turns in a row.
    private func drain() async {
        var last = fingerprint
        var quiet = 0
        for _ in 0 ..< Self.maxTurns {
            await Task.yield()
            let now = fingerprint
            if now == last {
                quiet += 1
                if quiet >= Self.quietTurns { return }
            } else {
                quiet = 0
                last = now
            }
        }
    }

    /// Everything a running chain touches on its way to its next wait.
    private var fingerprint: [Int] {
        [
            recorder.entries.count, clock.sleepCount, network.requests.count, network.delivered, audio.activity,
            vm.taskBag.count, silence.startListeningCallCount, silence.stopListeningCallCount,
            silence.commandEngineRequests.count, silence.isAnswerCaptureActive ? 1 : 0,
            vm.showAnswerConfirmation ? 1 : 0, vm.isEvaluatingAnswer ? 1 : 0, vm.recapEntries.count,
            vm.isPlayingAnyTTS ? 1 : 0,
        ]
    }

    private func spawn(_ body: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await body() })
    }

    // MARK: - Screen predicates (what the driver can reach right now)

    var questionReadOutsCompleted: [String] { audio.completedQuestionClips }

    var isSheetUp: Bool { vm.showAnswerConfirmation || vm.isEvaluatingAnswer }

    var isOnQuestionScreen: Bool {
        [.askingQuestion, .recording, .processing, .skipping].contains(vm.quizState)
    }

    /// The listening bar is up: the recogniser is armed for this screen.
    var isCommandWindowOpen: Bool { vm.commandListenerHint != nil }

    var isSheetEmpty: Bool {
        vm.transcribedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// AnswerConfirmationView disables Again until the countdown runs.
    private var isRerecordLocked: Bool {
        vm.settings.autoConfirmEnabled && vm.autoConfirmCountdown == 0 && !vm.isEditingTranscript && !vm.isPaused
    }

    private func noteSkipIntent() {
        skipIntents[vm.currentQuestion?.id ?? "-", default: 0] += 1
    }

    // MARK: - Inputs → the app

    private func perform(_ timed: TimedInput) -> Bool {
        let vm = vm
        switch timed.input {
        case let .tap(tap):
            return performTap(tap, detail: timed.detail)
        case let .command(command):
            guard isCommandWindowOpen else { return false }
            let screen = vm.voiceCommandCoordinator.currentCommandScreen
            if command == .skip, screen == .question { noteSkipIntent() }
            if command == .ok, screen == .confirmation, vm.showAnswerConfirmation, isSheetEmpty { noteSkipIntent() }
            vm.voiceCommandCoordinator.handleRecognizedCommand(command)
        case .speech(.speechStarted):
            guard silence.isAnswerCaptureActive else { return false }
            silence.simulateAnswerAudio(Data(count: 32000)) // 1 s of 16 kHz speech
            silence.simulateSilenceEvent(.speechStarted)
        case .speech(.audio):
            guard silence.isAnswerCaptureActive else { return false }
            silence.simulateAnswerAudio(Data(count: 32000))
        case .speech(.silenceAfterSpeech):
            guard silence.isAnswerCaptureActive else { return false }
            silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.2))
        case .speech(.bargeIn):
            guard vm.taskBag.contains(.bargeIn) else { return false }
            silence.simulateBargeIn()
        case let .network(reply):
            return network.resolveOldest(reply, detail: timed.detail)
        case .interruption:
            guard vm.quizState != .idle else { return false }
            audio.simulateInterruption()
        case .routeChange:
            vm.refreshAudioDevices()
        case .background:
            guard vm.isAppForeground else { return false }
            vm.handleScenePhase(.background)
        case .foreground:
            guard !vm.isAppForeground else { return false }
            vm.handleScenePhase(.active)
        case .idle:
            return false
        case .readOutEnd:
            return audio.finishQuestionClip()
        }
        return true
    }

    private func performTap(_ tap: QuizTap, detail: String?) -> Bool {
        let vm = vm
        let asking = vm.quizState == .askingQuestion && !isSheetUp
        switch tap {
        case .mic:
            guard !isSheetUp, vm.quizState == .askingQuestion || vm.quizState == .recording else { return false }
            spawn { await vm.toggleRecording() }
        case .confirm:
            guard vm.showAnswerConfirmation, !vm.isEvaluatingAnswer else { return false }
            if isSheetEmpty { noteSkipIntent() } // the Again/Skip sheet's Skip is this confirm
            spawn { await vm.confirmAnswer() }
        case .again:
            guard vm.showAnswerConfirmation, !vm.isEvaluatingAnswer, vm.noAnswerCaptured || !isRerecordLocked else { return false }
            vm.rerecordAnswer()
        case .cancel:
            guard vm.showAnswerConfirmation, !vm.isEvaluatingAnswer else { return false }
            vm.cancelProcessing()
        case .editTranscript:
            guard vm.showAnswerConfirmation, !vm.noAnswerCaptured, !vm.isEvaluatingAnswer else { return false }
            vm.beginEditingTranscript()
        case .mcqOption:
            guard !isSheetUp, vm.quizState == .askingQuestion || vm.quizState == .recording,
                  let options = vm.currentQuestion?.sortedAnswerOptions, let first = options.first,
                  vm.currentQuestion?.isMultipleChoice == true else { return false }
            let option = options.first { $0.key == detail } ?? first
            spawn { await vm.submitMCQAnswer(key: option.key, value: option.value) }
        case .skip:
            guard asking else { return false }
            noteSkipIntent()
            spawn { await vm.skipQuestion() }
        case .typedAnswer:
            guard asking else { return false }
            typedAnswers += 1
            let text = "typed \(typedAnswers)"
            spawn { await vm.resubmitAnswer(text) }
        case .replay:
            guard asking else { return false }
            spawn { await vm.replayQuestionAudio() }
        case .pause:
            // The pause pill lives in the question screen's toolbar only.
            guard isOnQuestionScreen, vm.canPauseQuiz || vm.isPaused else { return false }
            vm.togglePause()
        case .mute:
            guard isOnQuestionScreen else { return false }
            spawn { await vm.toggleMute() }
        case .next:
            guard vm.quizState.isShowingResult else { return false }
            vm.continueToNext()
        case .stay:
            guard vm.quizState.isShowingResult, !vm.isPaused else { return false }
            vm.pauseQuiz()
        case .resume:
            guard vm.quizState.isShowingResult, vm.isPaused else { return false }
            vm.resumeAutoAdvance()
        case .retry:
            guard vm.quizState.isError else { return false }
            if vm.shouldRetryWithNewSession {
                skipIntents = [:]
                vm.beginQuizStart()
            } else {
                spawn { await vm.retryLastOperation() }
            }
        case .playAgain:
            guard vm.quizState == .finished || vm.quizState == .idle else { return false }
            skipIntents = [:]
            vm.beginQuizStart()
        case .endWithResults:
            guard isOnQuestionScreen else { return false }
            spawn { await vm.endQuizWithResults() }
        }
        return true
    }
}
