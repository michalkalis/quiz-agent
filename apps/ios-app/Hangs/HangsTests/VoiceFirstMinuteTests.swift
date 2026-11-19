//
//  VoiceFirstMinuteTests.swift
//  HangsTests
//
//  #240.9 (founder 2026-11-18), the first minute of a voice answer. Store
//  data: new players finished no round, and most of their voice answers
//  reached the server as silence. The app waited 10 s, opened the mic for
//  5 s, uploaded the silence, was told "no speech" and retried on its own,
//  so one silent question became two "didn't catch that" rejections.
//
//  These pin the approved rules: the mic opens as soon as the question has
//  been read, with 15 s to start speaking; silence the phone measured is not
//  a failed attempt (nothing uploaded, no retry, a calm way on); a real
//  upload the server rejects keeps today's handling; a chosen think time is
//  kept. Plus the two #240 audit findings in the same answer path.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("#240.9 first minute of a voice answer")
@MainActor
struct VoiceFirstMinuteTests {
    private struct Rig {
        let vm: QuizViewModel
        let silence: MockSilenceDetectionService
        let network: MockNetworkService
        let analytics: MockAnalyticsClient
        let earcon: MockEarconPlayer
    }

    private func makeRig(clock: TestClock<Duration>, question: Question = Fixtures.makeQuestion(id: "q_001")) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        audio.micPermissionStatus = .granted
        let silence = MockSilenceDetectionService()
        let network = Fixtures.makeFullMockNetwork()
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock),
            analytics: analytics
        )
        let earcon = MockEarconPlayer()
        vm.earconPlayer = earcon
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = question
        vm.quizState = .askingQuestion
        return Rig(vm: vm, silence: silence, network: network, analytics: analytics, earcon: earcon)
    }

    /// The question has been read: open the hands-free window and let the
    /// 500 ms settle run, as after a real read-out.
    private func finishReadingQuestion(_ rig: Rig, _ clock: TestClock<Duration>) async {
        rig.vm.startRecordingOrTimer()
        await clock.advance(by: .milliseconds(Int(Config.autoRecordDelayMs)))
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the mic never opened after the read")
    }

    private var startWindow: Int { Int(Config.speechStartWindow + Config.immediateMicExtraWindow) }

    // MARK: - 1. The mic opens right after the question

    /// WHY: players did not know when to speak. With the new default the mic
    /// opens as soon as the question was read, says so (the mic-live tone, the
    /// "Speak now" bar) and counts the 15 s it keeps listening: the think time
    /// it replaces plus the old 5 s window.
    @Test("new default: the mic opens after the read with a 15 s visible window and the mic-live tone")
    func micOpensRightAfterTheRead() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        #expect(rig.vm.settings.thinkingTime == 0, "the new default has no think time")

        await finishReadingQuestion(rig, clock)

        #expect(rig.vm.answerWindowTotal == startWindow)
        #expect(rig.vm.answerWindowRemaining == startWindow, "the bar counts what the mic keeps listening")
        #expect(rig.earcon.played == [.micLive])
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// WHY: a player who set a think time chose that rhythm; the change is a
    /// new default, not an override.
    @Test("a chosen think time is kept: the countdown, then the usual 5 s to start")
    func chosenThinkTimeKept() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.vm.settings.thinkingTime = 15

        rig.vm.startRecordingOrTimer()
        await pumpUntil({ rig.vm.thinkingTimeCountdown == 15 }, "the think window never started")
        await clock.advance(by: .seconds(14))
        #expect(rig.vm.quizState == .askingQuestion, "the mic opened before the chosen think time ran out")
        await clock.advance(by: .seconds(1))
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the mic never opened")
        #expect(rig.vm.answerWindowTotal == Int(Config.speechStartWindow))
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// WHY: a tap means "I'm ready to answer"; only the hands-free opening
    /// carries the think time.
    @Test("a tap opens the mic with the usual 5 s to start")
    func tapKeepsShortWindow() async {
        let rig = makeRig(clock: TestClock())

        await rig.vm.toggleRecording()
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the mic never opened")

        #expect(rig.vm.answerWindowTotal == Int(Config.speechStartWindow))
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    // MARK: - 2. Silence is not a failed attempt

    /// WHY: the store data. Silence the phone measured went up to the server,
    /// came back "no speech" and was retried automatically, so the player
    /// heard twice that the app did not catch them. Now nothing is uploaded,
    /// nothing is spoken, the mic does not reopen by itself, and the question
    /// offers the ways on in a calm line, however long the player waits.
    @Test("measured silence: nothing uploaded, no retry, no 'didn't catch that', a calm prompt that waits")
    func silenceOffersCalmPrompt() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.silence.noSpeechWindowVerdict = .quiet

        await finishReadingQuestion(rig, clock)
        await clock.advance(by: .seconds(startWindow - 1))
        #expect(rig.vm.quizState == .recording, "the window closed before its 15 s")
        await clock.advance(by: .seconds(1))
        await pumpUntil({ rig.vm.quizState == .askingQuestion }, "the silent recording never ended")

        #expect(rig.network.submitVoiceAnswerCallCount == 0, "silence was uploaded")
        #expect(rig.vm.showsSilencePrompt)
        #expect(!rig.vm.showsEmptyAnswerRetryHint, "no \"didn't catch that\" line")
        #expect(rig.network.synthesizedTexts.isEmpty, "nothing spoken")
        #expect(!rig.vm.showAnswerConfirmation, "no Again / Skip sheet")
        #expect(!rig.silence.isAnswerCaptureActive)

        await clock.advance(by: .seconds(60))
        for _ in 0 ..< 30 {
            await Task.yield()
        }
        #expect(rig.vm.quizState == .askingQuestion, "the mic reopened by itself")
        #expect(rig.vm.showsSilencePrompt)
        #expect(rig.network.submitVoiceAnswerCallCount == 0)
        #expect(rig.network.submitTextInputCallCount == 0, "the question was skipped on the player's behalf")

        let reasons = rig.analytics.events(named: "voice_capture_failed").compactMap { event -> VoiceCaptureFailure? in
            guard case let .voiceCaptureFailed(reason, _) = event else { return nil }
            return reason
        }
        #expect(reasons == [.silent], "the silent outcome must be countable")
    }

    /// WHY: the prompt has to lead somewhere. A tap opens the mic again with
    /// the normal window and the line goes; "start" is one of the words the
    /// bar offers on that screen.
    @Test("from the prompt a tap opens the mic again and the prompt goes; \"start\" is offered")
    func speakAgainFromPrompt() async throws {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        await finishReadingQuestion(rig, clock)
        await clock.advance(by: .seconds(startWindow))
        await pumpUntil({ rig.vm.showsSilencePrompt }, "no prompt")

        let question = try #require(rig.vm.currentQuestion)
        let phase = try #require(rig.vm.listenPhase(for: question))
        #expect(phase.commands.contains(.start), "the spoken way back to the mic must be offered")

        await rig.vm.toggleRecording()
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the tap never reopened the mic")
        #expect(!rig.vm.showsSilencePrompt)
        #expect(rig.vm.answerWindowTotal == Int(Config.speechStartWindow))
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    /// WHY: only silence the phone can vouch for skips the server. When the
    /// detector cannot vouch, the recording is uploaded as before and a "no
    /// speech" answer from the server keeps today's spoken retry.
    @Test("an upload the server rejects keeps the automatic retry")
    func serverRejectionKeepsRetry() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.silence.noSpeechWindowVerdict = .possibleSpeech
        rig.network.submitVoiceAnswerError = NetworkError.serverError(statusCode: 400, message: "speech not understood")

        await finishReadingQuestion(rig, clock)
        rig.silence.simulateAnswerAudio(Data(count: 16000))
        let cap = Int(Config.autoRecordingDuration + Config.immediateMicExtraWindow)
        await advanceUntil(clock, limit: .seconds(cap + 5), { rig.network.submitVoiceAnswerCallCount == 1 }, "the cap never uploaded")

        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "no automatic retry")
        #expect(rig.network.synthesizedTexts == [SpokenPrompt.didNotCatch.text(language: .english)])
        #expect(!rig.vm.showsSilencePrompt)
        rig.vm.quizTimersController.cancelAutoStopRecordingTimer()
    }

    // MARK: - Settings

    /// WHY: "players who changed the think-time setting keep their value".
    /// A saved 10 s from an older build is that build's default and moves to
    /// the new one; anything else, and anything saved from now on, stays.
    @Test("think time: the old default moves to the new one, a choice stays")
    func thinkTimeMigration() throws {
        func decoded(thinkingTime: Int, version: Int?) throws -> Int {
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(QuizSettings.default)) as? [String: Any])
            json["thinkingTime"] = thinkingTime
            json["thinkingTimeDefaultVersion"] = version
            let data = try JSONSerialization.data(withJSONObject: json)
            return try JSONDecoder().decode(QuizSettings.self, from: data).thinkingTime
        }
        #expect(try decoded(thinkingTime: 10, version: nil) == 0, "an older build's default")
        #expect(try decoded(thinkingTime: 30, version: nil) == 30, "an older build's choice")
        #expect(try decoded(thinkingTime: 0, version: nil) == 0)
        #expect(try decoded(thinkingTime: 10, version: QuizSettings.currentThinkingTimeDefaultVersion) == 10, "a choice made on this build")
    }

    // MARK: - Measurement

    /// WHY: the next store numbers must say who opened the mic, how long after
    /// the question it opened, how loud the room was and whether the mic was
    /// allowed: the questions the 2026-11 data could not answer.
    @Test("answer_captured carries trigger, mic-open delay, peak level and mic permission")
    func answerCapturedMeasurement() async throws {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.silence.answerDetectionReport.peakDb = -42.4

        await finishReadingQuestion(rig, clock)
        await clock.advance(by: .seconds(startWindow))
        await pumpUntil({ rig.vm.showsSilencePrompt }, "no prompt")

        let captured = try #require(rig.analytics.events(named: "answer_captured").first)
        guard case let .answerCaptured(report) = captured else {
            Issue.record("not an answer_captured event")
            return
        }
        #expect(report.trigger == "auto")
        #expect(report.micOpenDelayMs == Int(Config.autoRecordDelayMs), "the mic opened 500 ms after the read")
        #expect(report.peakDb == -42)
        #expect(report.micPermission == "granted")
        #expect(report.stopReason == .noSpeechWindow)
        #expect(report.isRetry == false)
    }

    // MARK: - #240 audit findings

    /// WHY (audit 14): a typed answer sent while a skip was in flight took the
    /// skip's ownership. The skip's response was dropped and the quiz sat in
    /// `.skipping` until the 35 s watchdog showed "Failed to skip question",
    /// although the server had skipped it. The skip must land.
    @Test("a typed answer during an in-flight skip leaves the skip in charge")
    func typedAnswerDuringSkip() async {
        let rig = makeRig(clock: TestClock())
        let hold = rig.network.hold(.submitTextInput)

        let skip = Task { await rig.vm.skipQuestion() }
        await pumpUntil({ hold.heldCount == 1 }, "the skip never reached the server")
        #expect(rig.vm.quizState == .skipping)

        await rig.vm.resubmitAnswer("Paris")
        hold.release()
        await skip.value

        #expect(rig.vm.quizState != .skipping, "the quiz stayed stranded in .skipping")
        if case .error = rig.vm.quizState { Issue.record("a successful skip showed an error") }
        #expect(rig.network.submitTextInputCallCount == 1, "the typed answer went up after the skip")
        #expect(rig.vm.attemptLedger.invariantViolations.isEmpty)
    }

    /// WHY (audit 15): Skip on a multiple-choice question while the mic was
    /// open never ended the recording. With voice commands off the mic stayed
    /// live through the whole skip, the capture kept buffering, and the
    /// recording's detection session leaked into the next question.
    @Test("MCQ skip while the mic is open ends the recording")
    func mcqSkipWhileRecording() async {
        let rig = makeRig(clock: TestClock(), question: Self.mcqQuestion)
        rig.vm.settings.voiceCommandsEnabled = false
        let hold = rig.network.hold(.submitTextInput)

        await rig.vm.toggleRecording()
        await pumpUntil({ rig.vm.quizState == .recording && rig.silence.isAnswerCaptureActive }, "the mic never opened")
        #expect(rig.silence.isListening, "this recording started the engine itself")

        let skip = Task { await rig.vm.skipQuestion() }
        await pumpUntil({ hold.heldCount == 1 }, "the skip never reached the server")

        #expect(!rig.silence.isAnswerCaptureActive, "the capture kept buffering through the skip")
        #expect(!rig.silence.isAnswerDetectionActive, "the detection session leaked")
        #expect(!rig.silence.isListening, "the mic stayed live with voice commands off")

        hold.release()
        await skip.value
    }

    private static let mcqQuestion = Question(
        id: "q_mcq_240",
        question: "Largest planet?",
        type: .textMultichoice,
        possibleAnswers: ["a": "Mars", "b": "Jupiter", "c": "Venus", "d": "Saturn"],
        difficulty: "medium",
        topic: "Astronomy",
        category: "science",
        sourceUrl: nil,
        sourceExcerpt: nil,
        mediaUrl: nil,
        imageSubtype: nil,
        explanation: nil,
        generatedBy: nil
    )
}
