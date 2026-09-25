//
//  QuizSequenceRegressionTests.swift
//  HangsTests
//
//  #186 step 2 — minimal sequences the seeded harness found, frozen in the
//  flight-recorder dump format and replayed against the real view model. Each
//  one failed before its fix; the harness re-checks every invariant on replay.
//

import Foundation
@testable import Hangs
import Testing

@Suite("#186 quiz sequence regressions", .serialized)
@MainActor
struct QuizSequenceRegressionTests {
    /// WHY (harness seed 186109): muting — or pausing — while the recognised
    /// answer is read back stopped the playback from outside, and the read-back
    /// task then returned without dropping its TTS flag or arming anything. The
    /// sheet sat there: no auto-confirm, and voice commands off for good. A
    /// driver who mutes the app must still be carried on hands-free.
    @Test("muting during the answer read-back still auto-confirms and frees the command window")
    func muteDuringReadBack() async {
        let dump = """
        # quiz-sequence seed=0 questions=3 mcq=- autoRecord=1 thinking=10 autoConfirm=1 muted=0 commands=1 endOfSet=0 feedbackAudio=0 deafDetector=0
        00:00:00.000 state quizStart attempt=- state=idle
        00:00:05.000 tap mic attempt=q_001#1 state=askingQuestion
        00:00:05.500 speech vad.speechStarted attempt=q_001#2 state=recording
        00:00:06.500 speech vad.silenceAfterSpeech attempt=q_001#2 state=recording
        00:00:07.000 network voiceSubmit.transcript attempt=q_001#2 state=processing
        00:00:07.500 tap mute attempt=q_001#2 state=processing
        """
        let parsed = QuizSequenceDump.parse(dump)
        #expect(parsed.inputs.count == 5)

        let outcome = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs)

        #expect(outcome.violation == nil, "\(outcome.violation.map { "\($0.invariant): \($0.detail)" } ?? "")")
        #expect(outcome.run.vm.recapEntries.first?.userAnswerDisplay == "answer 1",
                "the countdown must still confirm the heard answer")
        #expect(outcome.run.vm.isPlayingAnswerReadBack == false, "a latched read-back keeps voice commands off")
    }
}
