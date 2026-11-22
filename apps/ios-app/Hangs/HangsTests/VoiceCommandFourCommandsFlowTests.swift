//
//  VoiceCommandFourCommandsFlowTests.swift
//  HangsTests
//
//  Founder decisions 2026-11-22, end to end through the coordinator: "next"
//  skips at once (the 2.5 s undo wait is gone) but only from a final result,
//  a recognised command answers with one quiet tick, and every fired command
//  reports its language so sk / cs can be compared with en.
//

import Clocks
import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeVM(
    language: String = "en",
    analytics: MockAnalyticsClient = MockAnalyticsClient()
) -> (QuizViewModel, MockEarconPlayer) {
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        // Parked: nothing on the quiz clock ever elapses, so any wait between
        // the command and its action would show as the action never happening.
        clock: AnyClock(TestClock()),
        analytics: analytics
    )
    vm.currentSession = Fixtures.makeActiveSession(language: language)
    vm.currentQuestion = Fixtures.makeQuestion()
    let earcon = MockEarconPlayer()
    vm.earconPlayer = earcon
    return (vm, earcon)
}

@Suite("Four voice commands — flow (founder 2026-11-22)")
@MainActor
struct VoiceCommandFourCommandsFlowTests {
    /// WHY (decision 5): the 2.5 s undo wait made "next" feel broken. A final
    /// "next" now skips at once — with the quiz clock parked, a skip that still
    /// waited on a timer would never happen.
    @Test("a final 'next' skips the question at once")
    func nextSkipsAtOnce() async {
        await withMainSerialExecutor {
            let (vm, _) = makeVM()
            vm.quizState = .askingQuestion

            await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: true))

            await pumpUntil({ vm.quizState != .askingQuestion }, "'next' did not skip without a wait")
        }
    }

    /// WHY (decision 3): with no undo behind it, a revisable hypothesis must
    /// not skip — even a stable one. Only the final does.
    @Test("a stable volatile 'next' does not skip; its final does")
    func nextWaitsForTheFinal() async {
        await withMainSerialExecutor {
            let (vm, _) = makeVM()
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .askingQuestion
            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: false))
            #expect(recognized.isEmpty, "a hypothesis must never skip the question")
            #expect(vm.quizState == .askingQuestion)

            await coordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: true))
            #expect(recognized == [.next])
        }
    }

    /// WHY (decision 3): "again" is the most lenient command and must not wait
    /// for a final anywhere. A stable hypothesis re-records on the sheet.
    @Test("a stable volatile 'again' re-records on the answer sheet")
    func againFiresFromStableVolatile() async {
        await withMainSerialExecutor {
            let (vm, _) = makeVM(language: "sk")
            let coordinator = vm.voiceCommandCoordinator
            vm.quizState = .processing
            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(CommandTranscript(text: "znova", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "znova", isFinal: false))

            #expect(recognized == [.again])
        }
    }

    /// WHY (decision 4): the haptic alone is easy to miss in a car mount; the
    /// player must hear that the command landed. One tick, through the same
    /// earcon funnel as the mic tone (so "Recording sounds" off silences it).
    @Test("a recognised command plays the tick with its haptic")
    func recognisedCommandTicks() {
        let (vm, earcon) = makeVM()
        vm.quizState = .askingQuestion

        vm.voiceCommandCoordinator.handleRecognizedCommand(.repeatQuestion)

        #expect(earcon.played == [.commandAck], "one tick, got \(earcon.played)")
        #expect(earcon.hapticsOnly.isEmpty)
    }

    @Test("with recording sounds off the tick is silent, the haptic stays")
    func tickFollowsRecordingSounds() {
        let (vm, earcon) = makeVM()
        vm.settings.recordingSoundsEnabled = false
        vm.quizState = .askingQuestion

        vm.voiceCommandCoordinator.handleRecognizedCommand(.repeatQuestion)

        #expect(earcon.played.isEmpty)
        #expect(earcon.hapticsOnly == [.commandAck])
    }

    /// WHY (decision 6): "are sk and cs recognised worse than en?" is answered
    /// by fired commands per command AND language next to the windows opened
    /// per language (`voice_command_window`). Without the language on the
    /// fire, the two cannot be divided.
    @Test("a fired command reports its language and which result fired it")
    func firedCommandCarriesLanguage() async {
        await withMainSerialExecutor {
            let analytics = MockAnalyticsClient()
            let (vm, _) = makeVM(language: "sk", analytics: analytics)
            vm.quizState = .askingQuestion

            await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "zopakuj", isFinal: true))

            let event = analytics.events(named: "voice_command").first
            #expect(event?.properties["command"] == .string("repeatQuestion"))
            #expect(event?.properties["language"] == .string("sk"))
            #expect(event?.properties["path"] == .string("final"))
        }
    }

    /// WHY (decision 6): latency is the other half of "worse": the time from
    /// the end of speech to the fire, measured on the quiz clock.
    @Test("a fired command reports the time since the speech ended")
    func firedCommandCarriesSpeechEndLatency() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let analytics = MockAnalyticsClient()
            let vm = QuizViewModel(
                networkService: Fixtures.makeFullMockNetwork(),
                audioService: MockAudioService(),
                persistenceStore: MockPersistenceStore(),
                silenceDetectionService: MockSilenceDetectionService(),
                clock: AnyClock(clock),
                analytics: analytics
            )
            vm.currentSession = Fixtures.makeActiveSession()
            vm.currentQuestion = Fixtures.makeQuestion()
            vm.quizState = .askingQuestion
            let coordinator = vm.voiceCommandCoordinator

            coordinator.noteSpeechActivity(.began(levelDb: -30, noiseFloorDb: -60))
            coordinator.noteSpeechActivity(.paused(speechSecs: 0.5, peakDb: -20))
            await clock.advance(by: .milliseconds(640))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "repeat", isFinal: true))

            let event = analytics.events(named: "voice_command").first
            #expect(event?.properties["speech_end_ms"] == .int(640))
        }
    }
}
