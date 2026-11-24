//
//  TimePresetsTests.swift
//  HangsTests
//
//  #243.8 (founder 2026-11-24, decision 6): the think time is 5 · 10 · 20 ·
//  30 s or "No limit" (the question waits for "answer" or a tap), and the
//  result moves on right after the verdict, 8 s or 15 s after it, or waits
//  for "next". Saved values from older builds move to the nearest preset once.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

private let baseBlob: [String: Any] = [
    "language": "en",
    "audioMode": "media",
    "numberOfQuestions": 8,
    "difficulty": "medium",
    "autoAdvanceDelay": 8,
    "answerTimeLimit": 30,
]

private func decode(_ json: [String: Any]) throws -> QuizSettings {
    try JSONDecoder().decode(QuizSettings.self, from: JSONSerialization.data(withJSONObject: json))
}

// MARK: - Saved values

@Suite("#243.8 time presets: saved values")
@MainActor
struct TimePresetsMigrationTests {
    /// WHY: the founder's presets replace the old seconds lists. A player who
    /// picked a length keeps roughly that length; the longest windows meant
    /// "give me time", which is now "No limit". 0 s (mic at once) is gone, so
    /// it becomes the shortest window.
    @Test("old think times move to the nearest preset", arguments: [
        (0, 5), (10, 10), (15, 20), (30, 30), (45, -1), (60, -1), (90, -1), (120, -1), (1, 5), (25, 20),
    ])
    func thinkTimeTable(saved: Int, expected: Int) throws {
        var json = baseBlob
        json["thinkingTime"] = saved
        json["thinkingTimeDefaultVersion"] = 3
        #expect(try decode(json).thinkingTime == expected)
    }

    /// WHY: build 90's 0 s default still goes back to 10 s first (the
    /// founder rejected it), not to the 5 s a chosen 0 now becomes.
    @Test("build 90's saved 0 s still becomes 10 s")
    func build90FixUpRunsFirst() throws {
        var json = baseBlob
        json["thinkingTime"] = 0
        json["thinkingTimeDefaultVersion"] = 2
        #expect(try decode(json).thinkingTime == 10)
    }

    /// WHY: 8 s was the untouched default and 5 s the "hurry" choice; both
    /// mean the new default, right after the verdict. 10 s keeps a pause
    /// (8 s), 15 s stays.
    @Test("old auto-advance delays move to the presets", arguments: [
        (5, 0), (8, 0), (10, 8), (15, 15), (3, 0), (30, 0),
    ])
    func autoAdvanceTable(saved: Int, expected: Int) throws {
        var json = baseBlob
        json["autoAdvanceDelay"] = saved
        #expect(try decode(json).autoAdvanceDelay == expected)
    }

    /// WHY: the move must run once. A blob this build saves carries the new
    /// versions, so the player's own choice, the sentinels included, is
    /// never moved again (an 8 s chosen now must not become "right after").
    /// (-1 = no limit / wait for "next", 0 = right after the verdict.)
    @Test("a re-saved blob keeps the player's choice", arguments: [(-1, -1), (20, 8), (5, 0)])
    func migrationRunsOnce(thinkingTime: Int, autoAdvance: Int) throws {
        var settings = QuizSettings.default
        settings.thinkingTime = thinkingTime
        settings.autoAdvanceDelay = autoAdvance
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let decoded = try decode(json)
        #expect(decoded.thinkingTime == thinkingTime)
        #expect(decoded.autoAdvanceDelay == autoAdvance)
        #expect(try decode(json) == settings)
    }

    /// WHY: guards the founder's lists and defaults (10 s to think, right
    /// after the verdict) against drifting without a decision.
    @Test("the presets and defaults are the founder's")
    func presets() {
        #expect(QuizSettings.thinkingTimeOptions == [5, 10, 20, 30, QuizSettings.unlimitedThinkingTime])
        #expect(QuizSettings.default.thinkingTime == 10)
        #expect(QuizSettings.autoAdvanceDelayOptions == [0, 8, 15, QuizSettings.waitForNextAutoAdvance])
        #expect(QuizSettings.default.autoAdvanceDelay == QuizSettings.rightAfterVerdictAutoAdvance)
    }
}

// MARK: - No limit

@Suite("#243.8 time presets: no think limit")
@MainActor
struct NoThinkLimitTests {
    private func makeVM(clock: TestClock<Duration>) -> (QuizViewModel, MockAudioService) {
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
        vm.settings.thinkingTime = QuizSettings.unlimitedThinkingTime
        return (vm, audio)
    }

    /// WHY (founder): "No limit" means the mic never opens by itself. The
    /// window says the short "Think." and shows no countdown, however long
    /// the player takes.
    @Test("the mic never opens on its own, the short think line plays, no countdown")
    func micNeverOpensOnItsOwn() async throws {
        let clock = TestClock()
        let (vm, audio) = makeVM(clock: clock)
        let think = try #require(PhasePrompt.think(seconds: nil).audio(language: .english))

        vm.startRecordingOrTimer()
        await pumpUntil({ audio.lastPlayedData == think }, "the short think line never played")
        await clock.advance(by: .seconds(600))
        await pumpUntil { true }

        #expect(vm.quizState == .askingQuestion, "the mic opened without a word or a tap")
        #expect(vm.thinkingTimeCountdown == 0)
        #expect(vm.answerWindowTotal == 0, "a countdown showed for a question without a limit")
        #expect(audio.lastPlayedData == think, "the answer line played without the player asking")
    }

    /// WHY (founder): the question waits for the spoken "answer"; it must
    /// still open the mic once the window has no limit.
    @Test("the spoken 'answer' opens the mic")
    func answerCommandOpensMic() async {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await clock.advance(by: .seconds(60))
        await pumpUntil { true }
        #expect(vm.quizState == .askingQuestion, "precondition")

        await vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "answer", isFinal: true))
        await pumpUntil({ vm.quizState == .recording }, "'answer' did not open the mic")
    }

    /// WHY (founder): or for a tap on the Answer button.
    @Test("a tap on Answer opens the mic")
    func tapOpensMic() async {
        let clock = TestClock()
        let (vm, _) = makeVM(clock: clock)
        vm.startRecordingOrTimer()
        await clock.advance(by: .seconds(60))
        await pumpUntil { true }

        await vm.toggleRecording()
        await pumpUntil({ vm.quizState == .recording }, "the tap did not open the mic")
    }
}

// MARK: - Result pace

@Suite("#243.8 time presets: result pace")
@MainActor
struct ResultPacePresetTests {
    private struct Rig {
        let vm: QuizViewModel
        let audio: MockAudioService
        let clock: TestClock<Duration>
    }

    private func makeRig(autoAdvance: Int) -> Rig {
        let clock = TestClock()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock)
        )
        vm.settleClock = AnyClock(clock)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.settings.autoAdvanceDelay = autoAdvance
        return Rig(vm: vm, audio: audio, clock: clock)
    }

    private let spokenVerdict = AudioInfo(feedbackUrl: nil, feedbackAudioBase64: "AAAA", questionUrl: nil, format: "opus")

    private func showResult(_ rig: Rig, audio: AudioInfo?) async {
        rig.vm.quizState = .processing
        await rig.vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_002"),
            evaluation: Evaluation(
                userAnswer: "4", result: .correct, points: 1, correctAnswer: "4",
                questionId: "q_001", explanation: nil
            ),
            feedbackReceived: [],
            audio: audio
        ))
        #expect(rig.vm.quizState.isShowingResult)
    }

    /// Holds the spoken verdict, then ends it.
    private func showHeldVerdict(_ rig: Rig) async {
        rig.audio.holdsPlaybackUntilStopped = true
        await showResult(rig, audio: spokenVerdict)
        await pumpUntil({ rig.audio.playOpusCallCount == 1 }, "the verdict was not spoken")
    }

    private func endVerdict(_ rig: Rig) async {
        rig.audio.holdsPlaybackUntilStopped = false
        await rig.audio.stopPlayback()
    }

    /// Asserts the result stays until just before `seconds`, then moves on.
    private func expectAdvance(_ rig: Rig, after seconds: Int) async {
        await rig.clock.advance(by: .milliseconds(seconds * 1000 - 100))
        #expect(rig.vm.quizState.isShowingResult, "moved on before \(seconds) s")
        _ = await advanceUntil(rig.clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.currentQuestion?.id == "q_002"
        }, "the result did not move on after \(seconds) s")
    }

    /// WHY (founder default "right after the verdict"): with nothing spoken
    /// the result still needs a moment to be read off the screen.
    @Test("right after the verdict, nothing spoken: the reading pause")
    func rightAfterWithoutVerdict() async {
        let rig = makeRig(autoAdvance: QuizSettings.rightAfterVerdictAutoAdvance)
        await showResult(rig, audio: nil)
        await pumpUntil({ rig.vm.autoAdvanceCountdown == Config.resultReadingPause }, "the reading pause never started")
        await expectAdvance(rig, after: Config.resultReadingPause)
    }

    /// WHY: the founder picked 8 s / 15 s to look at the result after the
    /// verdict, so the seconds count from the verdict's end, never over it,
    /// and the result never listens for "next" (only "wait" does).
    @Test("8 / 15 s count from the end of the spoken verdict", arguments: [8, 15])
    func secondsAfterSpokenVerdict(seconds: Int) async {
        let rig = makeRig(autoAdvance: seconds)
        await showHeldVerdict(rig)
        await pumpUntil({ rig.vm.isAwaitingSpokenVerdict }, "the result never waited for its verdict")
        #expect(rig.vm.autoAdvanceTotal == seconds, "the bar shows the pause that follows")
        await rig.clock.advance(by: .seconds(10))
        #expect(rig.vm.autoAdvanceCountdown == 0, "counted over the verdict")

        await endVerdict(rig)
        await pumpUntil({ rig.vm.autoAdvanceCountdown == seconds }, "the countdown never started")
        #expect(rig.vm.voiceCommandCoordinator.currentCommandScreen == nil, "a timed result listened for 'next'")
        await expectAdvance(rig, after: seconds)
    }

    /// WHY: with nothing spoken, 8 / 15 s count from the moment the result shows.
    @Test("8 / 15 s without a spoken verdict count at once", arguments: [8, 15])
    func secondsWithoutVerdict(seconds: Int) async {
        let rig = makeRig(autoAdvance: seconds)
        rig.vm.settings.isMuted = true
        await showResult(rig, audio: spokenVerdict)
        await pumpUntil({ rig.vm.autoAdvanceCountdown == seconds }, "the countdown did not start at once")
        await expectAdvance(rig, after: seconds)
    }

    /// WHY (founder "Wait for next"): no countdown at all, however long; the
    /// result listens for "next" only once the verdict has ended, so the
    /// verdict is never heard as a command.
    @Test("wait for next: no countdown, the 'next' window opens after the verdict")
    func waitNeverAdvancesOnTime() async {
        let rig = makeRig(autoAdvance: QuizSettings.waitForNextAutoAdvance)
        await showHeldVerdict(rig)
        await rig.clock.advance(by: .seconds(30))
        await pumpUntil { true }
        #expect(rig.vm.voiceCommandCoordinator.currentCommandScreen == nil, "listened while the verdict spoke")
        #expect(!rig.vm.isAwaitingSpokenVerdict, "a countdown was promised for a result that waits")

        await endVerdict(rig)
        await pumpUntil({ rig.vm.voiceCommandCoordinator.currentCommandScreen == .result }, "the 'next' window never opened")
        await rig.clock.advance(by: .seconds(600))
        await pumpUntil { true }
        #expect(rig.vm.quizState.isShowingResult, "the result moved on by itself")
        #expect(rig.vm.autoAdvanceCountdown == 0)
        #expect(VoiceCommandLexicon.commands(on: .result) == [.next], "the result hears only 'next'")
    }

    /// WHY (founder): "next" said on a waiting result goes on, like Next.
    @Test("wait for next: the spoken 'next' moves on")
    func spokenNextMovesOn() async {
        let rig = makeRig(autoAdvance: QuizSettings.waitForNextAutoAdvance)
        rig.vm.settings.isMuted = true
        await showResult(rig, audio: nil)
        await pumpUntil({ rig.vm.voiceCommandCoordinator.currentCommandScreen == .result }, "the 'next' window never opened")

        await rig.vm.voiceCommandCoordinator.handleCommandTranscript(CommandTranscript(text: "next", isFinal: true))
        _ = await advanceUntil(rig.clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.currentQuestion?.id == "q_002"
        }, "'next' did not move on")
    }

    /// WHY (founder): the Next button still moves on a waiting result.
    @Test("wait for next: the Next button moves on")
    func nextButtonMovesOn() async {
        let rig = makeRig(autoAdvance: QuizSettings.waitForNextAutoAdvance)
        await showResult(rig, audio: nil)
        await rig.clock.advance(by: .seconds(60))
        await pumpUntil { true }
        #expect(rig.vm.quizState.isShowingResult, "precondition")

        rig.vm.continueToNext()
        _ = await advanceUntil(rig.clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.currentQuestion?.id == "q_002"
        }, "Next did not move on")
    }
}
