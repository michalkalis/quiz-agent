//
//  CommandEngineSwitchTests.swift
//  HangsTests
//
//  #175 (founder 2026-09-09): voice commands are spoken in the QUIZ language,
//  with no Settings picker. The recognizer therefore has to change between
//  quizzes — these tests pin the swap's contract on the service: it happens
//  only when idle, it is a no-op when nothing changed, and it re-resolves
//  availability for the new locale.
//

import Foundation
import Speech
import Testing
@testable import Hangs

@Suite("Command engine follows the quiz language (#175)")
@MainActor
struct CommandEngineSwitchTests {
    private func makeService(_ selection: CommandEngineSelection) -> SilenceDetectionService {
        SilenceDetectionService(authorizationProvider: { .authorized }, selection: selection)
    }

    @Test("idle service swaps engine + locale and re-resolves availability")
    func switchesWhenIdle() async {
        let service = makeService(.speechEnglish)
        #expect(service.transcriberEngine.locale.identifier == "en_US")
        #expect(service.transcriberEngine.engineTag == "speech")

        await service.setCommandEngine(.dictationCzech)

        #expect(service.transcriberEngine.locale.identifier == "cs_CZ")
        #expect(service.transcriberEngine.engineTag == "dictation")
        // The asset flow ran for the NEW locale: availability is no longer the
        // reset value (on the Simulator it resolves to `.unavailable`; on a
        // device with the cs_CZ model it resolves to `.ready`). Either way the
        // stale answer for the old locale is gone — fail loud, never stale.
        #expect(service.commandAvailability != .unknown)
    }

    @Test("same selection is a no-op: availability and engine untouched")
    func noopWhenMatching() async {
        let service = makeService(.dictationSlovak)
        service.commandAvailability = .ready

        await service.setCommandEngine(.dictationSlovak)

        #expect(service.transcriberEngine.locale.identifier == "sk_SK")
        #expect(service.commandAvailability == .ready)
    }

    @Test("a switch is deferred while a listening window is starting")
    func deferredWhileStarting() async {
        let service = makeService(.speechEnglish)
        service.startInFlight = true
        defer { service.startInFlight = false }

        await service.setCommandEngine(.dictationSlovak)

        // Untouched — the per-window start path asks again next window.
        #expect(service.transcriberEngine.locale.identifier == "en_US")
    }

    @Test("dictation-English stays constructible for measurement, but no quiz language selects it")
    func dictationEnglishNotReachableFromQuizLanguage() {
        for code in ["en", "sk", "cs", "de", ""] {
            #expect(CommandEngineSelection.forQuizLanguage(code) != .dictationEnglish)
        }
    }

    /// #192: the quiz language is the SESSION's — a custom pack is played in
    /// its own language whatever Settings says, so the recognizer and the
    /// hints must follow the session, or a Slovak pack hears English commands.
    @Test("window start asks for the session language's engine BEFORE listening")
    func windowStartResolvesQuizLanguage() async {
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: MockElevenLabsSTTService()
        )
        vm.currentSession = Fixtures.makeActiveSession(language: "cs")
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        vm.settings.language = "en"

        await vm.audioDeviceState.startSilenceDetectionListening()

        #expect(silence.commandEngineRequests == [.dictationCzech])
        #expect(silence.isListening == true)
        // Everything above the seam follows the same value: Czech hints.
        #expect(vm.commandLanguage == .czech)

        // The next session's language lands on the NEXT window, no restart.
        vm.currentSession = Fixtures.makeActiveSession(language: "sk")
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(silence.commandEngineRequests.last == .dictationSlovak)
        #expect(vm.commandLanguage == .slovak)

        // Outside a session (Home) the Settings language is the quiz language.
        vm.currentSession = nil
        #expect(vm.commandLanguage == .english)
    }
}
