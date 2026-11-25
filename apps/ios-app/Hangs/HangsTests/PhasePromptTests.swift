//
//  PhasePromptTests.swift
//  HangsTests
//
//  #243.3 (founder 2026-11-24, decision 1): in the car, tones alone did not
//  say what was happening. The quiz now says "Think." when the think window
//  starts and "Answer." right before the mic opens on its own, in the app
//  voice from the bundle. #248 (founder 2026-11-25): only the first
//  question names the seconds, and "Answer." comes only before the mic opens
//  on its own, never when the player opens it.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#243.3: the quiz says which phase starts")
@MainActor
struct PhasePromptTests {
    private func makeVM(clock: TestClock<Duration> = TestClock()) -> (QuizViewModel, MockAudioService) {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentSession?.askedCount = 1
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        return (vm, audio)
    }

    private static let allPrompts: [PhasePrompt] =
        PhasePrompt.spokenThinkSeconds.sorted().map { .think(seconds: $0) }
            + [.think(seconds: nil), .thinkMore, .answer, .noAnswerOffer, .noAnswerOfferShort, .sayNext]

    /// WHY: the lines must play at once and without signal, in the app voice.
    /// A clip missing for one language would leave that quiz silent exactly
    /// where the founder asked for a word.
    @Test("every phase line is bundled in every quiz language", arguments: CommandLanguage.allCases)
    func everyClipIsBundled(language: CommandLanguage) throws {
        for prompt in Self.allPrompts {
            let audio = try #require(prompt.audio(language: language), "\(prompt.resourceName).\(language.rawValue)")
            #expect(audio.count > 1000, "\(prompt.resourceName).\(language.rawValue) is not a real clip")
        }
    }

    @Test("a think length without its own clip says the short line")
    func unknownLengthIsShort() {
        #expect(PhasePrompt.think(seconds: 45).resourceName == "think")
        #expect(PhasePrompt.think(seconds: 10).resourceName == "think-10")
    }

    /// WHY: the founder's flow, end to end. The window says the seconds first
    /// and only then drains, so the player keeps all ten; at zero the quiz
    /// says "Answer." and only then opens the mic.
    @Test("a fresh window says the long think line, drains, then says answer before the mic opens")
    func thinkThenAnswer() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let think = try #require(PhasePrompt.think(seconds: 10).audio(language: .english))
        let answer = try #require(PhasePrompt.answer.audio(language: .english))

        vm.startRecordingOrTimer()
        await pumpUntil({ audio.lastPlayedData == think }, "the think line never played")
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the window never started")
        #expect(vm.quizState == .askingQuestion, "the mic waits for the window")

        await clock.advance(by: .milliseconds(9999))
        #expect(audio.lastPlayedData == think, "nothing more before the window ends")
        await clock.advance(by: .milliseconds(2))
        await pumpUntil({ audio.lastPlayedData == answer }, "the answer line never played")
        await pumpUntil({ vm.quizState == .recording }, "the mic never opened after the answer line")
    }

    /// WHY (founder, TF b92): a long pause sat between the end of the question
    /// and "Think.". The read's tail armed the command listener and the line
    /// tore it straight down again; on a phone that is an audio engine start
    /// and stop (and on Bluetooth a route switch) the player hears as silence.
    /// The line now follows the read directly and the listener comes up after it.
    @Test("the think line follows the read at once, the listener comes up after it")
    func thinkLineFollowsReadWithoutListenerChurn() async throws {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentSession?.askedCount = 1
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.settings.thinkingTime = 10
        let think = try #require(PhasePrompt.think(seconds: 10).audio(language: .english))
        var listenerStartsBeforeLine: Int?
        audio.onPlaybackStarted = {
            if audio.lastPlayedData == think { listenerStartsBeforeLine = silence.startListeningCallCount }
        }

        await vm.audioDeviceState.playQuestionAudio(from: "https://example.invalid/q.opus")
        await pumpUntil({ listenerStartsBeforeLine != nil }, "the think line never played")
        #expect(listenerStartsBeforeLine == 0, "nothing may arm the listener between the read and the line")
        await pumpUntil({ silence.isListening }, "commands must work while the player thinks")
    }

    /// WHY: the read leaves the listener to the think line. When read-aloud
    /// goes off just as the read ends there is no line, and the player would
    /// think with voice commands dead.
    @Test("no think line after all: the listener still comes up")
    func noLineStillArmsListener() async {
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Question.preview
        vm.quizState = .askingQuestion
        vm.settings.isMuted = true
        #expect(!silence.isListening, "precondition")

        await vm.announcePhase(.thinkStart(seconds: 10))
        #expect(silence.isListening)
    }

    /// WHY (#248, founder 2026-11-25): the seconds are news once; hearing
    /// them again on every early question annoyed. Only the first question of
    /// a quiz says "Think, you have ten seconds."; from the second it is "Think.".
    @Test("only the first question says the long think line")
    func longOnlyOnFirstQuestion() async throws {
        let (vm, audio) = makeVM()
        vm.currentSession?.askedCount = 1
        await vm.announcePhase(.thinkStart(seconds: 10))
        #expect(audio.lastPlayedData == PhasePrompt.think(seconds: 10).audio(language: .english))

        for asked in [2, 3] {
            vm.currentSession?.askedCount = asked
            await vm.announcePhase(.thinkStart(seconds: 10))
            #expect(
                audio.lastPlayedData == PhasePrompt.think(seconds: nil).audio(language: .english),
                "question \(asked) must say the short line"
            )
        }
    }

    /// WHY (#248, founder 2026-11-25): "Answer." warns that the mic is about
    /// to open on its own. A player who opens it themselves knows already;
    /// the line would only talk into their answer.
    @Test("a tap on Answer opens the mic without the answer line")
    func tapSaysNoAnswerLine() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let answer = try #require(PhasePrompt.answer.audio(language: .english))
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the window never started")
        await clock.advance(by: .seconds(3))

        await vm.toggleRecording()
        await pumpUntil({ vm.quizState == .recording }, "the tap did not open the mic")
        await clock.advance(by: .seconds(8)) // past where the window would have ended
        #expect(!audio.playedData.contains(answer), "the answer line played on a tap")
        vm.taskBag.cancelAll()
    }

    /// WHY: same as the tap: the spoken "answer" is the player's own start.
    @Test("the spoken 'answer' opens the mic without the answer line")
    func voiceCommandSaysNoAnswerLine() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let answer = try #require(PhasePrompt.answer.audio(language: .english))
        vm.voiceCommandCoordinator.voiceStartOnQuestionEnabled = true
        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the window never started")
        await clock.advance(by: .seconds(3))

        vm.voiceCommandCoordinator.handleRecognizedCommand(.answer)
        await pumpUntil({ vm.quizState == .recording }, "'answer' did not open the mic")
        await clock.advance(by: .seconds(8))
        #expect(!audio.playedData.contains(answer), "the answer line played on the spoken command")
        vm.taskBag.cancelAll()
    }

    /// WHY: with read-aloud off nothing may speak; the screen carries the
    /// phase there. (A silent quiz never opens a think window at all.)
    @Test("read-aloud off says nothing")
    func mutedSaysNothing() async {
        let (vm, audio) = makeVM()
        await vm.toggleMute()
        #expect(vm.isAudioMuted, "precondition")
        await vm.announcePhase(.thinkStart(seconds: 10))
        await vm.announcePhase(.answerStart)
        #expect(audio.lastPlayedData == nil)
    }

    /// WHY (review of the #243.3 PR): a pause while "Answer." plays used to
    /// hold 0 seconds, which the resume read as a fresh window: the player
    /// got a whole new think window and heard "Think." again.
    @Test("a pause during the answer line resumes at the answer, not a fresh window")
    func pauseDuringAnswerLineResumesAtAnswer() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let think = try #require(PhasePrompt.think(seconds: 10).audio(language: .english))
        let answer = try #require(PhasePrompt.answer.audio(language: .english))

        vm.startRecordingOrTimer()
        await pumpUntil({ vm.thinkingTimeCountdown == 10 }, "the window never started")
        audio.holdsPlaybackUntilStopped = true
        await clock.advance(by: .seconds(11))
        await pumpUntil({ audio.lastPlayedData == answer }, "the answer line never started")

        vm.togglePause()
        audio.holdsPlaybackUntilStopped = false
        await audio.stopPlayback()
        #expect(vm.quizState == .askingQuestion, "the mic stays shut while paused")
        let thinkLines = audio.playedData.count { $0 == think }

        vm.togglePause()
        await pumpUntil({ vm.thinkingTimeCountdown == 1 }, "the resume did not go back to the answer")
        await clock.advance(by: .seconds(2))
        await pumpUntil({ vm.quizState == .recording }, "the mic never opened after the resume")
        #expect(audio.playedData.count { $0 == think } == thinkLines, "no second think line")
    }

    /// WHY: a pause holds the window; resuming it must not repeat the line
    /// for seconds the player already heard.
    @Test("a held window resumes without a word")
    func resumeIsSilent() async {
        let (vm, audio) = makeVM()
        vm.startRecordingOrTimer(resumingAt: 6)
        await pumpUntil({ vm.thinkingTimeCountdown == 6 }, "the held window never resumed")
        #expect(audio.playOpusCallCount == 0)
        vm.quizTimersController.cancelThinkingTime()
    }
}

extension MockAudioService {
    /// #243.3: clips played other than the bundled phase lines ("Think." /
    /// "Answer."), e.g. how often the question itself was read.
    var nonPhasePlayCount: Int {
        let lines = Set(CommandLanguage.allCases.flatMap { language in
            [PhasePrompt.think(seconds: nil), .answer, .thinkMore, .noAnswerOffer, .noAnswerOfferShort, .sayNext]
                .map { $0.audio(language: language) }
                + PhasePrompt.spokenThinkSeconds.map { PhasePrompt.think(seconds: $0).audio(language: language) }
        }.compactMap(\.self))
        return playedData.count { !lines.contains($0) }
    }
}
