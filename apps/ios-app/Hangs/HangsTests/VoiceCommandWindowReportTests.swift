//
//  VoiceCommandWindowReportTests.swift
//  HangsTests
//
//  Whether to stay on Apple's on-device recognizer for sk / cs / uk or pay
//  for a cloud one is a decision about numbers we did not have: per language
//  and engine, how many listening windows heard nothing, how many heard words
//  that matched no command, how many results came after the window closed,
//  and how long the first result took. `voice_command_window` carries exactly
//  those counts, once per window — never a word of what was said.
//

import Clocks
import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeVM(language: String = "sk") -> (QuizViewModel, MockSilenceDetectionService, MockAnalyticsClient, TestClock<Duration>) {
    let silence = MockSilenceDetectionService()
    let analytics = MockAnalyticsClient()
    let clock = TestClock()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        clock: AnyClock(clock),
        analytics: analytics
    )
    vm.currentSession = Fixtures.makeActiveSession(language: language)
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, analytics, clock)
}

@MainActor
private func reports(_ analytics: MockAnalyticsClient) -> [CommandWindowReport] {
    analytics.events(named: "voice_command_window").compactMap {
        if case let .voiceCommandWindow(report) = $0 { return report }
        return nil
    }
}

@Suite("voice_command_window — one report per listening window")
@MainActor
struct VoiceCommandWindowReportTests {
    /// WHY: "the window heard nothing" is the failure the old test runs found
    /// most (37 of 56 windows). It has to be countable per language and
    /// engine, which a report sent only when something was heard cannot do.
    @Test("a window that heard nothing reports zero transcripts and no first-result time")
    func silentWindow() async {
        await withMainSerialExecutor {
            let (vm, _, analytics, _) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics) == [CommandWindowReport(
                engine: "dictation", language: "sk", screen: "question",
                transcripts: 0, matched: 0, unmatched: 0, late: 0, cutOff: 0, firstTranscriptMs: nil
            )])
        }
    }

    /// WHY: matched vs unmatched finals is the recognition rate, and the time
    /// to the first result is the latency that decides whether a command can
    /// land inside a window at all.
    @Test("counts matched and unmatched utterances and the time to the first result")
    func countsAndLatency() async {
        await withMainSerialExecutor {
            let (vm, silence, analytics, clock) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()

            await clock.advance(by: .milliseconds(700))
            silence.simulateCommandTranscript("to bolo ťažké")
            await pumpUntil { vm.voiceCommandCoordinator.commandWindowStats?.transcripts == 1 }
            // Skip opens its undo window and stays on the question (the clock is held).
            silence.simulateCommandTranscript("preskoč")
            await pumpUntil { vm.voiceCommandCoordinator.commandWindowStats?.matched == 1 }
            vm.audioDeviceState.stopSilenceDetectionListening()

            let report = reports(analytics).first
            #expect(report?.transcripts == 2)
            #expect(report?.matched == 1)
            #expect(report?.unmatched == 1)
            #expect(report?.firstTranscriptMs == 700)
            #expect(analytics.events(named: "voice_command_window").count == 1)
        }
    }

    /// WHY: a result that lands after the window closed is a command the
    /// driver said in time and the app ignored — the case finalizing instead
    /// of cancelling is meant to fix, so it needs its own count.
    @Test("a transcript after the window closed counts as late, not unmatched")
    func lateTranscript() async {
        await withMainSerialExecutor {
            let (vm, silence, analytics, _) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            // The result screen has no command window.
            vm.quizState = .showingResult(
                question: Fixtures.makeQuestion(),
                evaluation: Evaluation(userAnswer: "x", result: .correct, points: 1, correctAnswer: "x", questionId: "q_001", explanation: nil)
            )
            silence.simulateCommandTranscript("preskoč")
            await pumpUntil { vm.voiceCommandCoordinator.commandWindowStats?.late == 1 }
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics).first?.late == 1)
            #expect(reports(analytics).first?.unmatched == 0)
        }
    }

    /// WHY: "said just before the window closed" is the other loss the old
    /// runs showed. An utterance still waiting for its final when the
    /// listener comes down is that case, and the count says how often a
    /// teardown that waits for the final would pay off.
    @Test("an utterance still in progress when the listener stops counts as cut off")
    func cutOffUtterance() async {
        await withMainSerialExecutor {
            let (vm, silence, analytics, _) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            // Skip waits for a final; the volatile alone only starts the utterance.
            silence.simulateCommandTranscript("preskoč", isFinal: false)
            await pumpUntil { vm.voiceCommandCoordinator.commandWindowStats?.transcripts == 1 }
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics).first?.cutOff == 1)
            #expect(reports(analytics).first?.matched == 0)
        }
    }

    /// WHY: on the question screen the window usually ends because the answer
    /// recording takes the shared engine, not because the listener stops. A
    /// command cut off there is the same loss and must be counted the same.
    @Test("an utterance cut off by the answer recording counts as cut off, once")
    func cutOffByRecording() async {
        await withMainSerialExecutor {
            let (vm, silence, analytics, _) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            silence.simulateCommandTranscript("preskoč", isFinal: false)
            await pumpUntil { vm.voiceCommandCoordinator.commandWindowStats?.transcripts == 1 }
            vm.quizState = .recording
            silence.simulateCommandTranscript("preskoč Bratislava")
            await pumpUntil { !reports(analytics).isEmpty }
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics).count == 1)
            #expect(reports(analytics).first?.cutOff == 1)
            #expect(reports(analytics).first?.late == 0)
        }
    }

    /// WHY: on the answer sheet anything that is not a command is a new
    /// answer — understood, not missed. Counting it as unmatched would make
    /// the sheet look broken exactly when it works.
    @Test("a new answer on the sheet is not an unmatched utterance")
    func newAnswerIsNotAMiss() async {
        await withMainSerialExecutor {
            let (vm, silence, analytics, _) = makeVM()
            vm.quizState = .processing
            await vm.audioDeviceState.startSilenceDetectionListening()
            silence.simulateCommandTranscript("Bratislava")
            // The new answer may close the sheet (and the window) by itself.
            await pumpUntil { vm.voiceCommandCoordinator.commandWindowStats?.transcripts == 1 || !reports(analytics).isEmpty }
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics).first?.screen == "confirmation")
            #expect(reports(analytics).first?.unmatched == 0)
        }
    }

    /// WHY: the listener is re-armed on the same screen many times (window
    /// syncs, route changes). Each re-arm is the same window for the driver;
    /// splitting it would inflate the "heard nothing" count.
    @Test("re-arming on the same screen keeps one window; a new screen starts another")
    func rearmKeepsOneWindow() async {
        await withMainSerialExecutor {
            let (vm, _, analytics, _) = makeVM(language: "en")
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            await vm.audioDeviceState.startSilenceDetectionListening()
            #expect(reports(analytics).isEmpty)

            vm.quizState = .processing
            await vm.audioDeviceState.startSilenceDetectionListening()
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics).map(\.screen) == ["question", "confirmation"])
            #expect(reports(analytics).map(\.engine) == ["speech", "speech"])
            #expect(reports(analytics).map(\.language) == ["en", "en"])
        }
    }

    /// WHY: the shared engine also records the answer; what it hears then is
    /// the answer, not a late command.
    @Test("transcripts during an answer recording are not counted")
    func recordingIsNotCounted() async {
        await withMainSerialExecutor {
            let (vm, silence, analytics, _) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            vm.quizState = .recording
            silence.simulateCommandTranscript("Bratislava")
            for _ in 0 ..< 50 {
                await Task.yield()
            }
            vm.audioDeviceState.stopSilenceDetectionListening()

            #expect(reports(analytics).first?.transcripts == 0)
            #expect(reports(analytics).first?.late == 0)
        }
    }

    /// WHY: the window opens with the recognizer biased toward this screen's
    /// commands — the service has to be told which screen that is.
    @Test("the listener is told the screen it listens for")
    func serviceLearnsTheScreen() async {
        await withMainSerialExecutor {
            let (vm, silence, _, _) = makeVM()
            vm.quizState = .askingQuestion
            await vm.audioDeviceState.startSilenceDetectionListening()
            #expect(silence.commandScreen == .question)
            vm.quizState = .processing
            await vm.audioDeviceState.startSilenceDetectionListening()
            #expect(silence.commandScreen == .confirmation)
        }
    }
}
