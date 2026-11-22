//
//  CommandHeardPreviewTests.swift
//  HangsTests
//
//  "What the app hears" (founder 2026-11-22): while the player speaks, a quiet
//  line names the command the words resemble and fills toward its threshold.
//  The rules it must keep: it never shows a word that is not a command, full
//  means fired, it clears by itself, a strict command fills more slowly than
//  a lenient one, it never speaks to VoiceOver, and a silent quiz shows none.
//

import Clocks
import ConcurrencyExtras
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
private func makeVM(clock: TestClock<Duration> = TestClock()) -> QuizViewModel {
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        clock: AnyClock(clock)
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    vm.earconPlayer = MockEarconPlayer()
    vm.quizState = .askingQuestion
    return vm
}

@Suite("What the app hears — live command preview (founder 2026-11-22)")
@MainActor
struct CommandHeardPreviewTests {
    // MARK: - The coordinator

    /// WHY: the point is "did it hear me?" before the command lands. A partial
    /// close to "repeat" names it at once, but below full: full means fired.
    @Test("a partial like a command shows it, not yet full")
    func partialShowsLabel() async {
        let vm = makeVM()
        await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "repea", isFinal: false))

        let heard = vm.commandHeard
        #expect(heard?.command == .repeatQuestion)
        #expect((heard?.certainty ?? 1) < 1, "an unfired command never shows full")
    }

    /// WHY: the founder's condition: never show words that are not commands
    /// (no transcript on screen, no half-sentences).
    @Test("speech that is not a command shows nothing", arguments: [
        "banana", "what about this one", "the answer is paris", "hmm",
    ])
    func nonCommandShowsNothing(text: String) async {
        let vm = makeVM()
        await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: text, isFinal: false))
        #expect(vm.commandHeard == nil, "'\(text)' must not show")
    }

    /// WHY: the label names the command in the screen's language, never what
    /// the recognizer wrote (a misspelt partial must not appear on screen).
    @Test("the label is the command's own word in the screen language")
    func labelIsCanonicalWord() {
        #expect(VoiceCommandLexicon.heardCaption(.repeatQuestion, language: .english) == "I hear: “repeat”")
        #expect(VoiceCommandLexicon.heardCaption(.repeatQuestion, language: .slovak) == "počujem: „zopakuj“")
        #expect(VoiceCommandLexicon.heardCaption(.again, language: .czech) == "slyším: „znovu“")
        #expect(VoiceCommandLexicon.heardCaption(.repeatQuestion, language: .ukrainian) == "чую: «повтори»")
    }

    /// WHY: on a fire the fill completes (with the tick), then the line goes by
    /// itself; it must not linger over the next screen.
    @Test("a fire fills it, then it clears")
    func fireFillsThenClears() async {
        await withMainSerialExecutor {
            let clock = TestClock()
            let vm = makeVM(clock: clock)
            let coordinator = vm.voiceCommandCoordinator
            await coordinator.handleCommandTranscript(CommandTranscript(text: "repea", isFinal: false))
            await coordinator.handleCommandTranscript(CommandTranscript(text: "repeat", isFinal: true))

            #expect(vm.commandHeard == .fired(.repeatQuestion))

            await clock.advance(by: CommandHeard.firedHold - .milliseconds(1))
            #expect(vm.commandHeard != nil, "the full fill is seen before it clears")
            await clock.advance(by: .milliseconds(1))
            #expect(vm.commandHeard == nil)
        }
    }

    /// WHY: an utterance that resembled a command and then became something
    /// else must not leave the guess on screen.
    @Test("an utterance that ends without firing clears it")
    func unfiredUtteranceClears() async {
        let vm = makeVM()
        let coordinator = vm.voiceCommandCoordinator
        await coordinator.handleCommandTranscript(CommandTranscript(text: "repea", isFinal: false))
        #expect(vm.commandHeard != nil)
        await coordinator.handleCommandTranscript(CommandTranscript(text: "repeat after me please", isFinal: true))
        #expect(vm.commandHeard == nil)
    }

    /// WHY (decision 3 carried into the preview): the fill maps onto each
    /// command's own threshold, so the strict "next" never looks as certain
    /// as the lenient "again" at the same similarity.
    @Test("next fills later than again for the same similarity")
    func nextFillsLaterThanAgain() throws {
        for score in [0.6, 0.65, 0.7] {
            let next = try #require(CommandHeard.inProgress(.next, score: score))
            let again = try #require(CommandHeard.inProgress(.again, score: score))
            #expect(next.certainty < again.certainty, "at \(score)")
        }
        #expect(CommandHeard.inProgress(.again, score: 0.5) == nil, "below the first resemblance")
    }

    /// WHY: "No sound" promises nothing listens; the preview is part of that.
    @Test("a silent quiz shows no preview")
    func silentQuizShowsNothing() async {
        let vm = makeVM()
        vm.settings.silentMode = true
        await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "repea", isFinal: false))
        #expect(vm.commandHeard == nil)
    }

    // MARK: - The views

    /// WHY: VoiceOver users hear what the command does; a running guess
    /// announced as it changes would talk over the question.
    @Test("VoiceOver never reads the guess")
    func voiceOverSkipsTheGuess() async throws {
        let heard = CommandHeard(command: .repeatQuestion, certainty: 0.5)
        let bar = ListenBar(mode: .command, heard: heard)
        try await ViewHosting.host(bar) {
            let tree = try bar.inspect()
            #expect(throws: Never.self) { try tree.find(text: "I hear: “repeat”") }
            let label = try tree.find(viewWithAccessibilityIdentifier: "listen-bar").accessibilityLabel().string()
            #expect(!label.contains("hear"), "the bar's VoiceOver label carried the guess: \(label)")
        }
        let line = CommandHeardLine(heard: heard)
        try await ViewHosting.host(line) {
            let hidden = try line.inspect().find(ViewType.Text.self).accessibilityHidden()
            #expect(hidden, "the quiet line is hidden from VoiceOver")
        }
    }
}
