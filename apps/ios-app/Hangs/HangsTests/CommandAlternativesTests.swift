//
//  CommandAlternativesTests.swift
//  HangsTests
//
//  Issue #184 track E — n-best. In a moving car the recognizer's TOP hypothesis
//  for a spoken command is routinely a wrong dictionary word while the real
//  command sits second in the n-best list, so a final whose primary text
//  matches nothing now retries the alternatives through the SAME screen-scoped
//  matcher.
//
//  The two rules these tests pin are the ones that keep it from becoming a
//  false-fire machine: alternatives are tried FINALS ONLY (a volatile is a
//  revisable guess already — scoring N guesses of a guess multiplies the
//  surface #119's stability gate exists to bound), and screen scoping still
//  applies to every alternative.
//

import Clocks
import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeCommandVM() -> QuizViewModel {
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        sttService: nil,
        clock: .continuous
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    vm.quizState = .showingResult(
        question: Fixtures.makeQuestion(),
        evaluation: Evaluation(
            userAnswer: "x", result: .correct, points: 1.0,
            correctAnswer: "x", questionId: "q_001", explanation: nil
        )
    )
    return vm
}

@Suite("Command n-best alternatives (#184)")
struct CommandAlternativesTests {

    /// WHY: this is the whole point of n-best. The founder said "next"; the
    /// engine ranked a wrong word first and "next" second. Before #184 that
    /// utterance did nothing at all.
    @Test("A final whose primary text matches nothing fires from an alternative")
    func alternativeFiresOnFinal() async {
        await withMainSerialExecutor {
            let vm = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "hello there", isFinal: true, alternatives: ["whatever", "next"])
            )

            #expect(recognized == [.next], "the n-best list is what carries the real command")
        }
    }

    /// WHY: a volatile hypothesis is already revisable, and #119 holds it to a
    /// near-exact floor precisely because the mic is open to the road and the
    /// passenger. Widening a volatile with N more hypotheses would hand every
    /// passing sentence several extra chances to hit the vocabulary.
    @Test("A volatile hypothesis never consults its alternatives")
    func alternativesIgnoredOnVolatile() async {
        await withMainSerialExecutor {
            let vm = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "hello there", isFinal: false, alternatives: ["next"])
            )

            #expect(recognized.isEmpty, "got \(recognized)")
        }
    }

    /// WHY: the primary transcript stays authoritative — an alternative is a
    /// fallback for "nothing matched", never a second opinion that can outvote
    /// a command the driver actually said.
    @Test("A matching primary wins; alternatives are not consulted")
    func primaryWinsOverAlternatives() async {
        await withMainSerialExecutor {
            let vm = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "next", isFinal: true, alternatives: ["ok"])
            )

            #expect(recognized == [.next])
        }
    }

    /// WHY: screen scoping is the confusion mitigation for a tiny vocabulary,
    /// and an alternative must not be a way around it — "start" is inert on the
    /// result screen whether it arrives first or fifth in the n-best list.
    @Test("An alternative inert on the current screen fires nothing")
    func alternativeStillScreenScoped() async {
        await withMainSerialExecutor {
            let vm = makeCommandVM()
            let coordinator = vm.voiceCommandCoordinator
            var recognized: [VoiceCommand] = []
            coordinator.onCommandRecognized = { recognized.append($0) }

            await coordinator.handleCommandTranscript(
                CommandTranscript(text: "hello there", isFinal: true, alternatives: ["start"])
            )

            #expect(recognized.isEmpty, "got \(recognized)")
        }
    }
}
