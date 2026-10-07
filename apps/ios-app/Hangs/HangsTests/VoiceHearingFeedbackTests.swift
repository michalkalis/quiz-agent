//
//  VoiceHearingFeedbackTests.swift
//  HangsTests
//
//  #122 follow-up (TF 2026-10-07, founder: no feedback that the app heard a
//  command). Between the first spoken syllable and the command firing (~1-2.5 s)
//  the bar was silent. `.hearing` (any speech while a window is armed) and
//  `.recognizing` (a command matched but is still waiting to fire) fill that
//  gap. Clock-driven: the glow timers sleep on the injected `TestClock`.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Voice hearing / recognizing feedback (#122 follow-up)")
@MainActor
struct VoiceHearingFeedbackTests {
    /// The coordinator holds its quiz-state closures weakly, so a test that
    /// discards the view model (`_`) would silently close every window.
    private static var retained: [QuizViewModel] = []

    private func make() -> (QuizViewModel, VoiceCommandCoordinator, MockSilenceDetectionService, TestClock<Duration>) {
        let clock = TestClock()
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: MockNetworkService(), audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(), silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.quizState = .askingQuestion
        Self.retained.append(vm)
        return (vm, vm.voiceCommandCoordinator, silence, clock)
    }

    // MARK: - Hearing

    @Test("Speech starting with a window armed lights hearing (the driver learns the mic caught them)")
    func speechStartedLightsHearing() async {
        let (_, coordinator, silence, _) = make()
        coordinator.startCommandConsumer()
        silence.simulateSilenceEvent(.speechStarted)
        await pumpUntil({ coordinator.voiceFeedbackPhase == .hearing }, "VAD speech never reached the bar")
    }

    @Test("Speech while TTS plays stays idle (the app's own voice is not the driver)")
    func ttsSpeechStaysIdle() {
        let (vm, coordinator, _, _) = make()
        vm.isPlayingQuestionTTS = true
        coordinator.noteSpeechStartedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("Speech with the window closed stays idle (a bar must not claim a mic that is down)")
    func closedWindowStaysIdle() {
        let (vm, coordinator, _, _) = make()
        vm.quizState = .recording
        coordinator.noteSpeechStartedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    @Test("silenceAfterSpeech clears hearing (speech is over, nothing left to say)")
    func silenceClearsHearing() async {
        let (_, coordinator, silence, _) = make()
        coordinator.startCommandConsumer()
        silence.simulateSilenceEvent(.speechStarted)
        await pumpUntil({ coordinator.voiceFeedbackPhase == .hearing })
        silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 1.0))
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle }, "hearing outlived the end of speech")
    }

    @Test("Hearing self-clears at 3.0 s (a rejected blip emits no end event)")
    func hearingAutoClears() async {
        let (_, coordinator, _, clock) = make()
        coordinator.noteSpeechStartedForFeedback()
        await Task.yield()
        await clock.advance(by: .milliseconds(2990))
        #expect(coordinator.voiceFeedbackPhase == .hearing)
        await clock.advance(by: .milliseconds(11))
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle }, "a blip must not leave the bar stuck")
    }

    @Test("Matched is never downgraded to hearing (the ack outranks it)")
    func matchedNotDowngraded() {
        let (_, coordinator, _, _) = make()
        coordinator.noteMatchedForFeedback()
        coordinator.noteSpeechStartedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    // MARK: - Recognizing

    @Test("A destructive command on a volatile shows recognizing with the command, then the final fires matched")
    func awaitingFinalThenMatched() async {
        let (_, coordinator, _, _) = make()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: false))
        #expect(coordinator.voiceFeedbackPhase == .recognizing)
        #expect(coordinator.recognizingCommand == .skip)

        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: true))
        #expect(coordinator.voiceFeedbackPhase == .matched)
        #expect(coordinator.recognizingCommand == nil, "recognizingCommand is non-nil only while recognizing")
    }

    @Test("A final that matches nothing does not leave recognizing stuck")
    func finalUnmatchedNotStuck() async {
        let (_, coordinator, _, _) = make()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: false))
        await coordinator.handleCommandTranscript(CommandTranscript(text: "completely unrelated words", isFinal: true))
        #expect(coordinator.voiceFeedbackPhase != .recognizing)
        #expect(coordinator.recognizingCommand == nil)
    }

    @Test("Recognizing self-clears at 3.0 s")
    func recognizingAutoClears() async {
        let (_, coordinator, _, clock) = make()
        coordinator.noteRecognizingForFeedback(.skip)
        await Task.yield()
        await clock.advance(by: .milliseconds(2990))
        #expect(coordinator.voiceFeedbackPhase == .recognizing)
        await clock.advance(by: .milliseconds(11))
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle }, "a never-firing command must not lie about progress")
        #expect(coordinator.recognizingCommand == nil)
    }

    @Test("Recognizing outranks hearing; unmatched replaces both; reset clears all")
    func precedenceAndReset() {
        let (_, coordinator, _, _) = make()
        coordinator.noteSpeechStartedForFeedback()
        coordinator.noteRecognizingForFeedback(.skip)
        #expect(coordinator.voiceFeedbackPhase == .recognizing)
        coordinator.noteSpeechStartedForFeedback()
        #expect(coordinator.voiceFeedbackPhase == .recognizing, "hearing lights only from idle")

        coordinator.noteUnmatchedForFeedback("some other words", isFinal: true)
        #expect(coordinator.voiceFeedbackPhase == .unmatched)
        #expect(coordinator.recognizingCommand == nil)

        coordinator.noteRecognizingForFeedback(.skip)
        coordinator.resetFeedbackGlow()
        #expect(coordinator.voiceFeedbackPhase == .idle)
        #expect(coordinator.recognizingCommand == nil)
    }

    @Test("The caption quotes the command word in the command language")
    func captionLanguage() {
        #expect(VoiceCommandLexicon.recognizingCaption(.skip, language: .english) == "\"skip\"…")
        #expect(VoiceCommandLexicon.recognizingCaption(.skip, language: .slovak) == "„preskoč“…")
    }
}
