//
//  QuizEndVoiceTests.swift
//  HangsTests
//
//  #188 track G (founder picks 2026-10-06, audit K1 / K2 / D3 / D4): the
//  moments where the quiz went silent and waited for a tap. An error, the
//  paywall and the end of the set each say one short line; the error screen
//  listens for "znova" only (stop / home words retired 2026-11-22); "hear it"
//  reads the explanation instead of replaying the verdict.
//  The round end (G3) lives in RoundEndVoiceTests since #243 decision 5.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private func drain() async {
    for _ in 0 ..< 30 {
        await Task.yield()
    }
}

@Suite("#188 G1, G2, G4 the quiz speaks where it used to go silent")
@MainActor
struct QuizEndVoiceTests {
    private struct Rig {
        let vm: QuizViewModel
        let silence: MockSilenceDetectionService
        let network: MockNetworkService
        let audio: MockAudioService

        var language: CommandLanguage {
            .forQuizLanguage(vm.currentSession?.language ?? vm.settings.language)
        }
    }

    private func makeRig() -> Rig {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing
        return Rig(vm: vm, silence: silence, network: network, audio: audio)
    }

    private func failSubmission(_ rig: Rig) {
        rig.vm.setError(message: "offline", context: .submission, error: URLError(.notConnectedToInternet))
    }

    // MARK: - G1

    /// WHY (K1, critical): at the wheel an error was pure silence and only a
    /// tap moved on. The driver must hear what happened and be able to retry
    /// by voice: "again" returns to the question exactly like the button.
    @Test("G1: an error says one line, then 'again' retries by voice")
    func errorSpeaksThenAgainRetries() async {
        let rig = makeRig()
        failSubmission(rig)

        await pumpUntil({ rig.vm.voiceCommandCoordinator.currentCommandScreen == .error }, "the error screen never listened")
        #expect(rig.network.synthesizedTexts == [SpokenPrompt.errorLine(commands: [.again], language: rig.language)])
        #expect(rig.audio.playOpusCallCount == 1, "the line was played once, no extra tone")

        await pumpUntil({ rig.silence.isListening }, "listener never came up")
        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.again, language: rig.language))
        await pumpUntil({ rig.vm.quizState == .askingQuestion }, "'again' did not retry")
    }

    /// WHY (founder 2026-11-22): "stop" / "domov" / "home" no longer act on the
    /// error screen — the only voice way off it is "again"; Home is a tap.
    @Test("G1: 'stop' on the error screen does nothing", arguments: ["stop", "home"])
    func errorStopIsInert(_ spoken: String) async {
        let rig = makeRig()
        failSubmission(rig)
        await pumpUntil({ rig.silence.isListening && rig.vm.voiceCommandCoordinator.currentCommandScreen == .error })
        var recognized: [VoiceCommand] = []
        rig.vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }

        rig.silence.simulateCommandTranscript(spoken)
        await drain()
        #expect(recognized.isEmpty, "'\(spoken)' acted on the error screen")
        #expect(rig.vm.quizState != .idle)
    }

    /// WHY: the most common error is a dropped connection — exactly when the
    /// line can no longer be fetched. The line fetched at quiz start plays.
    @Test("G1: with the network gone, the prefetched line still plays")
    func prefetchedLineSurvivesOffline() async {
        let rig = makeRig()
        rig.vm.prefetchErrorPrompt()
        await pumpUntil({ !rig.vm.prefetchedPromptAudio.isEmpty }, "nothing was prefetched")
        rig.network.shouldFail = true

        failSubmission(rig)
        await pumpUntil({ rig.audio.playOpusCallCount == 1 }, "the offline error stayed silent")
        #expect(rig.network.synthesizedTexts.count == 1, "played from the prefetch, not fetched again")
    }

    /// WHY: with voice commands off nothing listens, so the line must not
    /// promise words; it still says what happened.
    @Test("G1: commands off → the line names no command and nothing listens")
    func errorWithoutCommands() async {
        let rig = makeRig()
        rig.vm.settings.voiceCommandsEnabled = false
        failSubmission(rig)

        await pumpUntil({ rig.audio.playOpusCallCount == 1 }, "the error stayed silent")
        await drain()
        #expect(rig.network.synthesizedTexts == [SpokenPrompt.errorLine(commands: [], language: rig.language)])
        #expect(rig.silence.isListening == false)
    }

    // MARK: - G2

    /// WHY (K2, critical): the quota cut ended the quiz and opened the paywall
    /// without a word, which reads as a crash while driving. One line first.
    @Test("G2: running out of free questions says one line before the paywall")
    func quotaSpeaksBeforePaywall() async {
        let rig = makeRig()
        let limit = QuotaLimitError(
            error: "quota_limit_reached", questionsUsed: 30, questionsLimit: 30,
            resetsAt: "2099-01-01T00:00:00Z", upgradeAvailable: true
        )
        await rig.vm.handleError(NetworkError.quotaLimitReached(limit), context: .submission, fallbackMessage: "x")

        #expect(rig.network.synthesizedTexts == [SpokenPrompt.quotaReachedLine(language: rig.language)])
        #expect(rig.audio.playOpusCallCount == 1)
        #expect(rig.vm.showPaywall)
        #expect(rig.vm.quizState == .idle)
    }

    /// WHY (#199): a Trubbo Plus subscriber who spent the month's allowance must
    /// not be told their "free" questions ran out; the line names what ran out.
    @Test("G2: a subscriber who spent the allowance hears about Trubbo Plus questions, not free ones")
    func quotaSpeaksAboutThePlanForSubscribers() async {
        let rig = makeRig()
        let limit = QuotaLimitError(
            error: "quota_limit_reached", questionsUsed: 1000, questionsLimit: 1000,
            resetsAt: "2099-01-01T00:00:00Z", upgradeAvailable: false
        )
        await rig.vm.handleError(NetworkError.quotaLimitReached(limit), context: .submission, fallbackMessage: "x")

        let line = SpokenPrompt.quotaReachedLine(language: rig.language, upgradeAvailable: false)
        #expect(rig.network.synthesizedTexts == [line])
        #expect(line.contains("Trubbo Plus"))
        #expect(!line.localizedCaseInsensitiveContains("free"))
        #expect(rig.vm.showPaywall)
    }

    // MARK: - G4

    /// WHY (D4): "hear it" sits on the explanation but replayed the verdict.
    /// It must read the explanation itself.
    @Test("G4: 'hear it' reads the explanation")
    func hearItReadsExplanation() async {
        let rig = makeRig()
        let question = Fixtures.makeQuestion(id: "q_001")
        rig.vm.quizState = .showingResult(
            question: question,
            evaluation: Evaluation(userAnswer: "b", result: .incorrect, points: 0, correctAnswer: "a", questionId: "q_001", explanation: nil)
        )

        rig.vm.readExplanationAloud("Venus is hotter because of its thick atmosphere.")
        await pumpUntil({ rig.audio.playOpusCallCount == 1 }, "nothing was read")
        #expect(rig.network.synthesizedTexts == ["Venus is hotter because of its thick atmosphere."])
    }
}

@Suite("#188 G1/G3 quiz-end command words — sk / cs / en / uk")
struct QuizEndCommandWordTests {
    private func match(_ phrase: String, _ screen: VoiceCommandScreen, _ language: CommandLanguage) -> VoiceCommand? {
        VoiceCommandMatcher.match(transcript: phrase, on: screen, isFinal: true, language: language)
    }

    /// WHY: the founder's words for the two screens, in every quiz language at
    /// once (the lexicon parity rule). #243 decision 5: the round end also
    /// takes "domov"; the error screen still does not (retired 2026-11-22).
    @Test("again routes on both quiz-end screens, home at the round end only", arguments: CommandLanguage.allCases)
    func founderWords(_ language: CommandLanguage) {
        let again = VoiceCommandLexicon.spokenWord(.again, language: language)
        let home = VoiceCommandLexicon.spokenWord(.home, language: language)
        #expect(match(again, .error, language) == .again)
        #expect(match(again, .setEnd, language) == .again)
        #expect(match(home, .setEnd, language) == .home)
        #expect(match(home, .error, language) == nil)
        #expect(VoiceCommandLexicon.commands(on: .error) == [.again])
        #expect(VoiceCommandLexicon.commands(on: .setEnd) == [.again, .home])
    }

    /// WHY: on the sheet "nie" re-records an answer; at the set end it would
    /// start a whole new quiz from a passenger's "no".
    @Test("sentence openers and 'wait' do nothing at the quiz end", arguments: CommandLanguage.allCases)
    func quizEndExclusions(_ language: CommandLanguage) {
        for word in VoiceCommandLexicon.quizEndExcludedVariants(for: language) {
            #expect(match(word, .setEnd, language) == nil, "\(word) must not act at the set end")
            #expect(match(word, .error, language) == nil, "\(word) must not act on the error screen")
        }
    }

    /// WHY: the spoken lines name only words the screen really acts on, and
    /// carry no quote marks the voice would read out (copy rule 10).
    @Test("spoken lines name valid words, without quote marks", arguments: CommandLanguage.allCases)
    func spokenLinesAreHonest(_ language: CommandLanguage) {
        let lines = [
            (SpokenPrompt.errorLine(commands: [.again], language: language), VoiceCommandScreen.error),
            (SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [.again, .home], language: language), .setEnd),
        ]
        for (line, screen) in lines {
            #expect(!line.contains("\"") && !line.contains("„") && !line.contains("“") && !line.contains("«"))
            for command in VoiceCommandLexicon.commands(on: screen) {
                let word = VoiceCommandLexicon.spokenWord(command, language: language)
                #expect(line.localizedCaseInsensitiveContains(word), "\(line) must name \(word)")
                #expect(match(word, screen, language) == command)
            }
        }
        #expect(SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [], language: language).contains("7"))
    }
}
