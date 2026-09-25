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

    /// WHY (harness known bug, seed 186000): the auto-advance countdown ran the
    /// advance inside its own `.autoAdvance` task, and the advance begins by
    /// cancelling `.autoAdvance` — itself. The rest ran cancelled, so the next
    /// question's read-out ended the instant it started: a hands-free driver
    /// never heard question 2 and its countdown started at once.
    @Test("an auto-advanced question is read aloud to the end")
    func autoAdvanceReadsNextQuestion() async {
        let dump = """
        # quiz-sequence seed=0 questions=3 mcq=- autoRecord=1 thinking=10 autoConfirm=1 muted=0 commands=1 endOfSet=0 feedbackAudio=0 deafDetector=0
        00:00:00.000 state quizStart attempt=- state=idle
        00:00:02.943 tap skip attempt=q_001#1 state=askingQuestion
        00:00:03.065 network quizResponse attempt=q_001#2 state=skipping correct
        00:00:20.000 timer idle attempt=q_002#3 state=askingQuestion
        """
        let parsed = QuizSequenceDump.parse(dump)
        let outcome = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs)

        #expect(outcome.violation == nil, "\(outcome.violation.map { "\($0.invariant): \($0.detail)" } ?? "")")
        #expect(outcome.run.questionReadOutsCompleted.contains("q_002"), "question 2 was never read to the end")
    }

    /// WHY (harness known bug): a replay tap during the first read-out stopped
    /// it, and that read's tail then cleared the "question is being read" flag
    /// while the REPLAY was playing. The hands-free start waits only on that
    /// flag (#185 founder rule), so with no think time it opened the mic over
    /// the replay — the question was cut off by the app, not the driver.
    @Test("a replay during the first read-out keeps the hands-free start waiting")
    func replayKeepsReadOutFlag() async {
        let dump = """
        # quiz-sequence seed=0 questions=3 mcq=- autoRecord=1 thinking=0 autoConfirm=1 muted=0 commands=1 endOfSet=0 feedbackAudio=0 deafDetector=0
        00:00:00.000 state quizStart attempt=- state=idle
        00:00:00.919 tap replay attempt=q_001#1 state=askingQuestion
        00:00:10.000 timer idle attempt=q_001#1 state=askingQuestion
        """
        let parsed = QuizSequenceDump.parse(dump)
        let outcome = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs)

        #expect(outcome.violation == nil, "\(outcome.violation.map { "\($0.invariant): \($0.detail)" } ?? "")")
        #expect(outcome.run.questionReadOutsCompleted.filter { $0 == "q_001" }.count == 1, "the replay must play to its end")
    }

    /// WHY: a TestFlight black box must replay without hand edits. The step-1
    /// recorder left out the Skip, Next, Pause and Mute taps and when a
    /// question read-out ended, so a field dump could not reproduce what the
    /// driver did or heard. Replaying a dump must now leave the app's own
    /// black box describing the same inputs, in the same order.
    @Test("a field dump replays, and the replay's black box records the same inputs")
    func fieldDumpRoundTrips() async {
        let dump = """
        Quiz flight recorder — field dump, production defaults
        16:02:00.000 state idle→startingQuiz attempt=-#0 state=startingQuiz beginQuizStart
        16:02:04.700 prompt questionReadOut.end attempt=q_001#1 state=askingQuestion completed
        16:02:06.000 tap pause attempt=q_001#1 state=askingQuestion
        16:02:09.000 tap pause attempt=q_001#1 state=askingQuestion
        16:02:10.000 tap mute attempt=q_001#1 state=askingQuestion
        16:02:11.000 tap mute attempt=q_001#1 state=askingQuestion
        16:02:12.000 tap skip attempt=q_001#1 state=askingQuestion
        16:02:12.900 network quizResponse attempt=q_001#2 state=skipping skipped
        16:02:14.000 tap next attempt=q_001#2 state=showingResult
        16:02:19.300 prompt questionReadOut.end attempt=q_002#3 state=askingQuestion completed
        """
        let parsed = QuizSequenceDump.parse(dump)
        #expect(parsed.config.readOutEndsFromDump)
        #expect(parsed.inputs.map(\.input) == [
            .readOutEnd, .tap(.pause), .tap(.pause), .tap(.mute), .tap(.mute),
            .tap(.skip), .network(.textEvaluated), .tap(.next), .readOutEnd,
        ])

        let outcome = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs)

        #expect(outcome.violation == nil, "\(outcome.violation.map { "\($0.invariant): \($0.detail)" } ?? "")")
        #expect(outcome.run.log.allSatisfy { $0.applied }, "every input of the dump must reach the app")
        #expect(outcome.run.questionReadOutsCompleted.prefix(2) == ["q_001", "q_002"])
        let recorded = QuizSequenceDump.parse(outcome.run.recorder.dump()).inputs.map(\.input)
        #expect(Array(recorded.prefix(parsed.inputs.count)) == parsed.inputs.map(\.input),
                "the replay's own black box must describe the inputs that drove it")
    }

    /// WHY (harness seed 186115, founder decision 2026-09-25): with reveal at
    /// the end, the auto-confirm sent question 2's answer and the advance to
    /// question 3 was already on its way when the driver said "stop" (or
    /// "again"). That reopened question 2 for a moment — a new attempt, the
    /// advance then landing on top of it (rejected transition), and "again"
    /// even starting a recording the advance cut off. A sent answer is final:
    /// the late command is dropped and reported, the quiz moves on.
    @Test("stop / again after the answer is sent are dropped, never reopen the question", arguments: ["stop", "again"])
    func commandAfterAnswerSentIsDropped(command: String) async {
        let dump = """
        # quiz-sequence seed=186115 questions=4 mcq=4 autoRecord=0 thinking=0 autoConfirm=1 muted=0 commands=1 endOfSet=1 feedbackAudio=0 deafDetector=0
        00:00:00.000 state quizStart attempt=- state=idle
        00:00:32.242 tap mute attempt=q_001#1 state=askingQuestion
        00:00:52.891 tap confirm attempt=q_001#3 state=processing
        00:01:00.605 network quizResponse attempt=q_001#4 state=skipping correct
        00:01:06.533 tap mic attempt=q_002#5 state=askingQuestion
        00:01:12.919 speech vad.speechStarted attempt=q_002#7 state=recording
        00:01:14.234 speech vad.silenceAfterSpeech attempt=q_002#7 state=recording
        00:01:18.489 network voiceSubmit.transcript attempt=q_002#7 state=processing
        00:01:23.585 command \(command) attempt=q_002#7 state=processing
        """
        let parsed = QuizSequenceDump.parse(dump)
        let outcome = await QuizSequenceHarness.replay(config: parsed.config, inputs: parsed.inputs)
        let entries = outcome.run.recorder.entries

        #expect(outcome.violation == nil, "\(outcome.violation.map { "\($0.invariant): \($0.detail)" } ?? "")")
        #expect(!entries.contains { $0.kind == .reject }, "the advance collided with a reopened question")
        #expect(entries.contains { $0.kind == .drop && $0.name.hasSuffix(".afterAnswerSent") },
                "the late command must be reported as dropped")
        #expect(!entries.contains { $0.kind == .attempt && ($0.name == "cancelProcessing" || $0.name == "rerecord") },
                "question 2 was reopened after its answer was sent")
        #expect(outcome.run.vm.recapEntries.count >= 2 && outcome.run.vm.recapEntries[1].userAnswerDisplay != nil,
                "question 2's sent answer must stand")
    }
}
