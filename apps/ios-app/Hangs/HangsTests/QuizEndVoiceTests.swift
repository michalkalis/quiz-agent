//
//  QuizEndVoiceTests.swift
//  HangsTests
//
//  #188 track G (founder picks 2026-10-06, audit K1 / K2 / D3 / D4): the
//  moments where the quiz went silent and waited for a tap. An error, the
//  paywall and the end of the set each say one short line, and the error and
//  score screens listen for "znova" / "stop" / "domov"; "hear it" reads the
//  explanation instead of replaying the verdict.
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

@Suite("#188 G1–G4 the quiz speaks where it used to go silent")
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
            sttService: nil,
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
        #expect(rig.network.synthesizedTexts == [SpokenPrompt.errorLine(commands: [.again, .stop], language: rig.language)])
        #expect(rig.audio.playOpusCallCount == 1, "the line was played once, no extra tone")

        await pumpUntil({ rig.silence.isListening }, "listener never came up")
        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.again, language: rig.language))
        await pumpUntil({ rig.vm.quizState == .askingQuestion }, "'again' did not retry")
    }

    /// WHY: "stop" is the spoken twin of Go Home.
    @Test("G1: 'stop' on the error screen goes Home")
    func errorStopGoesHome() async {
        let rig = makeRig()
        failSubmission(rig)
        await pumpUntil({ rig.silence.isListening && rig.vm.voiceCommandCoordinator.currentCommandScreen == .error })

        rig.silence.simulateCommandTranscript("stop")
        await pumpUntil({ rig.vm.quizState == .idle }, "'stop' did not go Home")
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

    // MARK: - G3

    /// WHY (D3): in the per-question flow the set ended in silence; the driver
    /// never learned the score. It is said, the music gets its volume back,
    /// and the score screen listens on the quiet session like Home.
    @Test("G3: the set end says the score, then 'home' goes Home")
    func setEndSpeaksScoreAndListens() async {
        let rig = makeRig()
        rig.vm.sessionCorrectCount = 7
        await rig.vm.handleError(NetworkError.sessionFinished, context: .submission, fallbackMessage: "x")
        #expect(rig.vm.quizState == .finished)

        await pumpUntil({ rig.silence.isListening && rig.vm.voiceCommandCoordinator.currentCommandScreen == .setEnd },
                        "the score screen never listened")
        #expect(rig.network.synthesizedTexts == [
            SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [.again, .home], language: rig.language),
        ])
        #expect(rig.audio.deactivateSessionCallCount >= 1, "the quiz session was released")
        #expect(rig.audio.setupQuietListeningSessionCallCount >= 1, "listening must not duck the music")

        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.home, language: rig.language))
        await pumpUntil({ rig.vm.quizState == .idle }, "'home' did not go Home")
    }

    /// WHY: the end-of-set recap already reads itself aloud — a score line on
    /// top would talk over it, and its narration must not reach a live mic.
    @Test("G3: the recap ending adds no score line and opens no listener")
    func recapEndingStaysAsItWas() async {
        let (vm, network) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()))
        vm.settings.answerRevealMode = .endOfSet
        vm.settings.autoRecordEnabled = false
        vm.settings.answerTimeLimit = 0
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .processing

        await vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "Input processed",
            session: Fixtures.makeQuizSession(phase: "finished"),
            currentQuestion: nil,
            evaluation: Evaluation(
                userAnswer: "a", result: .correct, points: 1, correctAnswer: "a",
                questionId: "q_001", explanation: nil, headlineAnswer: nil
            ),
            feedbackReceived: [],
            audio: nil
        ))
        // The deferred advance runs on real sleeps (#180 track A).
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while vm.quizState != .finished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(vm.quizState == .finished)
        #expect(vm.endsOnRecap)
        await drain()

        #expect(network.synthesizedTexts.isEmpty)
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)
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

@Suite("#188 G1/G3 quiz-end command words — sk / cs / en")
struct QuizEndCommandWordTests {
    private func match(_ phrase: String, _ screen: VoiceCommandScreen, _ language: CommandLanguage) -> VoiceCommand? {
        VoiceCommandMatcher.match(transcript: phrase, on: screen, isFinal: true, language: language)
    }

    /// WHY: the founder's words for the two screens, in every quiz language at
    /// once (the lexicon parity rule).
    @Test("again / stop / home route in every language", arguments: CommandLanguage.allCases)
    func founderWords(_ language: CommandLanguage) {
        let again = VoiceCommandLexicon.spokenWord(.again, language: language)
        let home = VoiceCommandLexicon.spokenWord(.home, language: language)
        #expect(match(again, .error, language) == .again)
        #expect(match("stop", .error, language) == .stop)
        #expect(match(again, .setEnd, language) == .again)
        #expect(match(home, .setEnd, language) == .home)
    }

    /// WHY: on the sheet "nie" re-records an answer; at the set end it would
    /// start a whole new quiz from a passenger's "no". And "home" must not act
    /// mid-quiz, where nothing routes it.
    @Test("sentence openers and 'wait' do nothing at the quiz end; 'home' only there", arguments: CommandLanguage.allCases)
    func quizEndExclusions(_ language: CommandLanguage) {
        for word in VoiceCommandLexicon.quizEndExcludedVariants(for: language) {
            #expect(match(word, .setEnd, language) == nil, "\(word) must not act at the set end")
            #expect(match(word, .error, language) == nil, "\(word) must not act on the error screen")
        }
        let home = VoiceCommandLexicon.spokenWord(.home, language: language)
        for screen in [VoiceCommandScreen.home, .question, .confirmation, .result, .error] {
            #expect(match(home, screen, language) == nil, "\(home) must not act on \(screen)")
        }
    }

    /// WHY: the spoken lines name only words the screen really acts on, and
    /// carry no quote marks the voice would read out (copy rule 10).
    @Test("spoken lines name valid words, without quote marks", arguments: CommandLanguage.allCases)
    func spokenLinesAreHonest(_ language: CommandLanguage) {
        let lines = [
            (SpokenPrompt.errorLine(commands: [.again, .stop], language: language), VoiceCommandScreen.error),
            (SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [.again, .home], language: language), .setEnd),
        ]
        for (line, screen) in lines {
            #expect(!line.contains("\"") && !line.contains("„") && !line.contains("“"))
            for command in VoiceCommandLexicon.commands(on: screen) {
                let word = VoiceCommandLexicon.spokenWord(command, language: language)
                #expect(line.contains(word), "\(line) must name \(word)")
                #expect(match(word, screen, language) == command)
            }
        }
        #expect(SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [], language: language).contains("7"))
    }
}
