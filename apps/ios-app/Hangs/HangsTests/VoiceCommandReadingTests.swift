//
//  VoiceCommandReadingTests.swift
//  HangsTests
//
//  #208.7 (founder, TF 2026-10-16): the bar offered "repeat" / "skip" while the
//  question was read, but the listener was down for the whole read. Now an
//  echo-cancelling listener that is already live stays up through it — and
//  everything that makes listening over the app's own voice safe is pinned
//  here: when it may stay up, the echo guard, which commands route, and that
//  the read path neither tears it down nor re-arms it.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#208.7 voice commands while the question is read")
@MainActor
struct VoiceCommandReadingTests {
    private static var retained: [QuizViewModel] = []

    private static let armed = VoiceProcessingStatus(mode: .on, armed: true, outputPort: "Speaker")
    private static let questionText = "Which city is the capital of France"

    /// A question screen whose listener is live: flag on, voice processing as
    /// given, the consumer armed.
    private func make(
        flag: Bool = true, voiceProcessing: VoiceProcessingStatus? = armed
    ) async -> (QuizViewModel, VoiceCommandCoordinator, MockSilenceDetectionService, MockAudioService) {
        let silence = MockSilenceDetectionService()
        silence.voiceProcessingOnStart = voiceProcessing
        let audio = MockAudioService()
        audio.playbackDurationNs = 1_000_000
        let vm = QuizViewModel(
            networkService: MockNetworkService(), audioService: audio,
            persistenceStore: MockPersistenceStore(), silenceDetectionService: silence,
            clock: AnyClock(TestClock())
        )
        vm.quizState = .askingQuestion
        vm.currentQuestion = Fixtures.makeQuestion(text: Self.questionText)
        vm.voiceCommandCoordinator.commandsDuringReadingEnabled = { flag }
        Self.retained.append(vm)
        await vm.audioDeviceState.startSilenceDetectionListening()
        return (vm, vm.voiceCommandCoordinator, silence, audio)
    }

    // MARK: - When the listener may stay up

    @Test("kept only with the flag on and a live, voice-processing engine")
    func keepMatrix() async {
        let (vmOn, on, _, _) = await make()
        #expect(on.beginQuestionRead())
        vmOn.isPlayingQuestionTTS = true
        #expect(on.mayCaptureAudio, "the kept engine may run under the question read")
        #expect(on.currentCommandScreen == .question)

        let (_, off, _, _) = await make(flag: false)
        #expect(!off.beginQuestionRead(), "rollback switch off = today's behaviour")

        // WHY: without echo cancellation (car stereo, CarPlay, wired) the
        // recognizer would transcribe the question itself.
        let (_, noVP, _, _) = await make(voiceProcessing: VoiceProcessingStatus(mode: .offOutput, armed: false, outputPort: "BluetoothA2DPOutput"))
        #expect(!noVP.beginQuestionRead())
    }

    /// WHY: only the QUESTION read is covered; result feedback still closes
    /// the window, and nothing may start an engine under a playing clip.
    @Test("feedback TTS, or a read the listener was not kept for, still closes capture")
    func otherTTSStillCloses() async {
        let (vm, coordinator, _, _) = await make()
        _ = coordinator.beginQuestionRead()
        vm.isPlayingQuestionTTS = true
        vm.isPlayingFeedbackTTS = true
        #expect(!coordinator.mayCaptureAudio)

        let (vm2, notKept, _, _) = await make(flag: false)
        _ = notKept.beginQuestionRead()
        vm2.isPlayingQuestionTTS = true
        #expect(!notKept.mayCaptureAudio, "no kept engine: no capture under the read")
    }

    // MARK: - Read path

    /// WHY: tearing the engine down for every read is what made the read's
    /// commands deaf, and re-arming it after re-minted its streams.
    @Test("the read keeps the live listener: no stop, no restart, edges suspended then resumed")
    func readPathKeepsListener() async {
        let (vm, _, silence, audio) = await make()
        let stopsBefore = silence.stopListeningCallCount
        let startsBefore = silence.startListeningCallCount
        var listeningWhilePlaying = false
        audio.onPlaybackStarted = { listeningWhilePlaying = silence.isListening }

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.com/q.mp3")

        #expect(listeningWhilePlaying, "the mic stays live under the read")
        #expect(silence.stopListeningCallCount == stopsBefore)
        #expect(silence.startListeningCallCount == startsBefore)
        #expect(silence.speechEdgeSuspensions == [true, false])
        #expect(!vm.isPlayingQuestionTTS)
    }

    @Test("flag off: the read tears the listener down and re-arms it after, as before")
    func readPathRollback() async {
        let (vm, _, silence, audio) = await make(flag: false)
        var listeningWhilePlaying = true
        audio.onPlaybackStarted = { listeningWhilePlaying = silence.isListening }
        await vm.audioDeviceState.playQuestionAudio(from: "https://example.com/q.mp3")
        #expect(!listeningWhilePlaying)
        #expect(silence.isListening, "the tail brings it back")
        #expect(silence.speechEdgeSuspensions.isEmpty)
    }

    // MARK: - Echo guard + routing during the read

    private func reading() async -> (QuizViewModel, VoiceCommandCoordinator, [VoiceCommand]) {
        let (vm, coordinator, _, _) = await make()
        _ = coordinator.beginQuestionRead()
        vm.isPlayingQuestionTTS = true
        return (vm, coordinator, [])
    }

    /// WHY: the recognizer hears the read through any leak; its words must
    /// neither fire a command nor light "didn't catch that".
    @Test("the read's own words are dropped silently")
    func echoDropped() async {
        let (_, coordinator, _) = await reading()
        var fired: [VoiceCommand] = []
        coordinator.onCommandRecognized = { fired.append($0) }
        await coordinator.handleCommandTranscript(CommandTranscript(text: "which city is the capital", isFinal: true))
        #expect(fired.isEmpty)
        #expect(coordinator.voiceFeedbackPhase == .idle, "no amber for the app's own voice")
    }

    /// WHY: with leaky echo cancellation the driver's word arrives merged into
    /// the read's residue — stripping, not rejecting, is what lets it through.
    @Test("a command merged into echo still fires")
    func commandInsideEcho() async {
        let (_, coordinator, _) = await reading()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "the capital of France skip", isFinal: true))
        #expect(coordinator.pendingSkipWindow != nil)
    }

    /// WHY: a cancel word that also occurs in the question ("no") must still
    /// abort a skip said over the read.
    @Test("a cancel word survives the echo guard")
    func cancelWordSurvivesGuard() async {
        let (vm, coordinator, _, _) = await make()
        vm.currentQuestion = Fixtures.makeQuestion(text: "Is the answer no or yes")
        _ = coordinator.beginQuestionRead()
        vm.isPlayingQuestionTTS = true
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))
        #expect(coordinator.pendingSkipWindow != nil)
        await coordinator.handleCommandTranscript(CommandTranscript(text: "no", isFinal: true))
        #expect(coordinator.pendingSkipWindow == nil)
    }

    /// WHY: an echo segment's final can arrive after the read ended.
    @Test("an utterance that began during the read stays guarded to its final")
    func lateEchoFinalGuarded() async {
        let (vm, coordinator, _) = await reading()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "which city", isFinal: false))
        vm.isPlayingQuestionTTS = false
        coordinator.endQuestionRead()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "which city is the capital of france", isFinal: true))
        #expect(coordinator.voiceFeedbackPhase != .unmatched)
    }

    /// WHY: "start" opens the answer mic — over the read it would record the
    /// question.
    @Test("start does not route during the read")
    func startBlocked() async {
        let (vm, coordinator, _) = await reading()
        var fired: [VoiceCommand] = []
        coordinator.onCommandRecognized = { fired.append($0) }
        await coordinator.handleCommandTranscript(CommandTranscript(text: "start", isFinal: true))
        #expect(fired.isEmpty)
        #expect(vm.quizState == .askingQuestion)
    }

    /// WHY: the ack tone is muted under the question, so the read stopping is
    /// how the driver hears that "skip" worked — and the think window must not
    /// start under the pending skip.
    @Test("skip during the read stops the read and starts no think window")
    func skipStopsRead() async {
        let (vm, coordinator, _, audio) = await make()
        audio.playbackDurationNs = 2_000_000_000
        audio.onPlaybackStarted = {
            Task { await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true)) }
        }
        await vm.audioDeviceState.playQuestionAudio(from: "https://example.com/q.mp3")
        #expect(coordinator.pendingSkipWindow != nil)
        #expect(vm.quizTimersController.thinkingTimeCountdown == 0)
    }
}
