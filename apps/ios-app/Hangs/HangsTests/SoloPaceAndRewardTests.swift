//
//  SoloPaceAndRewardTests.swift
//  HangsTests
//
//  #240.9 (founder 2026-11-18), pace and reward in the solo round. Store data:
//  a ten-question round was more waiting than playing (the result sat a fixed
//  8 s, counting while the verdict was still spoken), a good run went
//  unmentioned, and a player who hit the monthly limit on an answer never
//  learnt whether it was right: the paywall replaced the verdict and the
//  round's score.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("#240.9 solo round: pace and reward")
@MainActor
struct SoloPaceAndRewardTests {
    private struct Rig {
        let vm: QuizViewModel
        let audio: MockAudioService
        let analytics: MockAnalyticsClient
    }

    private func makeRig(clock: TestClock<Duration>) -> Rig {
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock),
            analytics: analytics
        )
        // The advance's 100 ms audio settle runs on the test's clock too, so
        // the whole result → next question chain is driven, never waited for.
        vm.settleClock = AnyClock(clock)
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        return Rig(vm: vm, audio: audio, analytics: analytics)
    }

    private func evaluation(
        _ result: Evaluation.EvaluationResult,
        id: String = "q_001",
        answer: String = "4"
    ) -> Evaluation {
        Evaluation(
            userAnswer: result == .skipped ? "" : answer,
            result: result,
            points: result == .correct ? 1 : 0,
            correctAnswer: answer,
            questionId: id,
            explanation: nil
        )
    }

    private let spokenVerdict = AudioInfo(feedbackUrl: nil, feedbackAudioBase64: "AAAA", questionUrl: nil, format: "opus")

    /// The answer to q_001 comes back graded, with or without its spoken verdict.
    private func showResult(_ rig: Rig, audio: AudioInfo?) async {
        rig.vm.quizState = .processing
        await rig.vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "",
            session: Fixtures.makeQuizSession(),
            currentQuestion: Fixtures.makeQuestion(id: "q_002"),
            evaluation: evaluation(.correct),
            feedbackReceived: [],
            audio: audio
        ))
        #expect(rig.vm.quizState.isShowingResult)
    }

    // MARK: - Item 5: the result moves on a short moment after the spoken verdict

    /// WHY: the countdown used to run 8 s from the moment the result showed,
    /// over the verdict being spoken. Now nothing counts while the verdict
    /// speaks (the bar shows it held full), and the result moves on 3 s after
    /// the verdict ends: as long as the verdict, plus a breath.
    @Test("a spoken verdict holds the countdown until it ends, then 3 s to the next question")
    func countdownFollowsTheSpokenVerdict() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.audio.holdsPlaybackUntilStopped = true
        await showResult(rig, audio: spokenVerdict)

        await pumpUntil({ rig.vm.isAwaitingSpokenVerdict }, "the result never waited for its spoken verdict")
        #expect(rig.vm.autoAdvanceCountdown == 0, "nothing counts while the verdict is spoken")
        #expect(rig.vm.autoAdvanceTotal == Config.pauseAfterSpokenVerdict, "the bar shows the short pause that follows")
        await clock.advance(by: .seconds(10))
        #expect(rig.vm.quizState.isShowingResult, "a long verdict is never cut off by the countdown")

        rig.audio.holdsPlaybackUntilStopped = false
        await rig.audio.stopPlayback() // the verdict ends
        await pumpUntil({ rig.vm.autoAdvanceCountdown == Config.pauseAfterSpokenVerdict }, "the short countdown never started")
        #expect(!rig.vm.isAwaitingSpokenVerdict)
        #expect(rig.vm.autoAdvanceTotal == Config.pauseAfterSpokenVerdict)

        await clock.advance(by: .milliseconds(Config.pauseAfterSpokenVerdict * 1000 - 100))
        #expect(rig.vm.quizState.isShowingResult, "moved on before the pause after the verdict was over")
        _ = await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.currentQuestion?.id == "q_002"
        }, "the result did not move on 3 s after the verdict ended")
    }

    /// WHY (founder 2026-11-22): "Read aloud" off promises the app reads
    /// nothing, the result included. The verdict the server sent stays
    /// unspoken, the result is read on screen instead: it keeps the Settings
    /// pause for that, counted at once, and moves on without waiting for audio.
    @Test("read aloud off: the result speaks no verdict, keeps the Settings pause and moves on")
    func mutedResultSpeaksNothingAndMovesOn() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.vm.settings.isMuted = true
        await showResult(rig, audio: spokenVerdict)

        await pumpUntil({ rig.vm.autoAdvanceCountdown == rig.vm.settings.autoAdvanceDelay }, "the countdown did not start at once")
        #expect(rig.audio.playOpusCallCount == 0, "the verdict was spoken with read aloud off")
        #expect(!rig.vm.isAwaitingSpokenVerdict)
        #expect(rig.vm.autoAdvanceTotal == rig.vm.settings.autoAdvanceDelay)

        await clock.advance(by: .milliseconds(rig.vm.settings.autoAdvanceDelay * 1000 - 100))
        #expect(rig.vm.quizState.isShowingResult, "moved on before the Settings pause was over")
        _ = await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.currentQuestion?.id == "q_002"
        }, "the unspoken result did not move on after its pause")
        #expect(rig.audio.playOpusCallCount == 0, "the verdict was spoken late")
    }

    /// WHY: CarPlay plays through the same result and reads the same switch,
    /// so read aloud off is silent in the car too (silent mode is not).
    @Test("read aloud off in CarPlay: the result speaks no verdict")
    func mutedCarPlayResultSpeaksNothing() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.vm.isCarPlaySceneForeground = true
        rig.vm.settings.isMuted = true
        await showResult(rig, audio: spokenVerdict)

        await pumpUntil({ rig.vm.autoAdvanceCountdown == rig.vm.settings.autoAdvanceDelay }, "the countdown did not start at once")
        #expect(rig.audio.playOpusCallCount == 0, "the verdict was spoken in CarPlay with read aloud off")
        rig.vm.taskBag.cancel(.autoAdvance)
    }

    /// WHY: read aloud on is unchanged, the verdict is spoken.
    @Test("read aloud on: the result speaks its verdict")
    func unmutedResultSpeaksTheVerdict() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        await showResult(rig, audio: spokenVerdict)

        await pumpUntil({ rig.audio.playOpusCallCount == 1 }, "the verdict was not spoken with read aloud on")
        await pumpUntil({ rig.vm.autoAdvanceCountdown == Config.pauseAfterSpokenVerdict }, "the short countdown never started")
        rig.vm.taskBag.cancel(.autoAdvance)
    }

    /// WHY: a verdict whose download stalls must not keep the result still
    /// with no visible reason: past 12 s the countdown starts anyway.
    @Test("a stalled verdict starts the countdown after 12 s at most")
    func stalledVerdictIsCapped() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.audio.holdsPlaybackUntilStopped = true
        await showResult(rig, audio: spokenVerdict)
        await pumpUntil({ rig.vm.isAwaitingSpokenVerdict }, "the result never waited for its spoken verdict")

        await clock.advance(by: Config.spokenVerdictWaitCap - .milliseconds(100))
        #expect(rig.vm.autoAdvanceCountdown == 0, "the cap fired early")
        await clock.advance(by: .milliseconds(100))
        await pumpUntil({ rig.vm.autoAdvanceCountdown == Config.pauseAfterSpokenVerdict }, "the stalled verdict held the result forever")
        #expect(!rig.vm.isAwaitingSpokenVerdict)
        rig.audio.holdsPlaybackUntilStopped = false
        await rig.audio.stopPlayback()
    }

    /// WHY: a tap on the result (or STAY) while the verdict is spoken means
    /// "let me look": the result must not move on when the verdict ends.
    @Test("a pause while the verdict is spoken holds the result after it ends")
    func pauseDuringTheVerdictHolds() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.audio.holdsPlaybackUntilStopped = true
        await showResult(rig, audio: spokenVerdict)
        await pumpUntil({ rig.vm.isAwaitingSpokenVerdict }, "the result never waited for its spoken verdict")

        rig.vm.pauseQuiz()
        await pumpUntil({ !rig.vm.isAwaitingSpokenVerdict }, "the pause did not end the wait")
        rig.audio.holdsPlaybackUntilStopped = false
        await rig.audio.stopPlayback()
        await clock.advance(by: .seconds(30))
        #expect(rig.vm.quizState.isShowingResult, "a paused result moved on by itself")
        #expect(rig.vm.autoAdvanceCountdown == 0)
    }

    // MARK: - Item 6: a run of right answers, and the line the round ends on

    /// Answers `results` one after another through the real result path.
    private func play(_ rig: Rig, _ results: [(Evaluation.EvaluationResult, String)]) async {
        rig.vm.settings.isMuted = true
        for (index, (result, difficulty)) in results.enumerated() {
            let id = "q_\(index + 1)"
            rig.vm.taskBag.cancelAll()
            var question = Fixtures.makeQuestion(id: id)
            question = Question(
                id: id, question: question.question, type: .text, possibleAnswers: nil,
                difficulty: difficulty, topic: question.topic, category: question.category,
                sourceUrl: question.sourceUrl, sourceExcerpt: question.sourceExcerpt, mediaUrl: nil,
                imageSubtype: nil, explanation: nil, generatedBy: nil, reviewBadge: nil,
                translationLanguage: nil, reviewNote: nil
            )
            rig.vm.currentQuestion = question
            rig.vm.quizState = result == .skipped ? .skipping : .processing
            await rig.vm.handleQuizResponse(QuizResponse(
                success: true, message: "", session: Fixtures.makeQuizSession(),
                currentQuestion: Fixtures.makeQuestion(id: "q_next"),
                evaluation: evaluation(result, id: id, answer: "Answer \(index + 1)"),
                feedbackReceived: [], audio: nil
            ))
        }
        rig.vm.taskBag.cancelAll()
    }

    /// WHY: the app counted runs and never showed them; a run is the reward a
    /// round can give mid-way. It starts at three in a row (two is chance) and
    /// counts this round only, so the first answer of a round is never "4 in a
    /// row" from yesterday.
    @Test("the result says the run from 3 right answers in a row, counted in this round")
    func resultShowsTheRunFromThree() async {
        let rig = makeRig(clock: TestClock())
        await play(rig, [(.correct, "easy"), (.correct, "easy")])
        #expect(rig.vm.resultStreak == nil, "two in a row is not called out")

        await play(rig, [(.correct, "easy"), (.correct, "easy"), (.correct, "easy")])
        #expect(rig.vm.resultStreak == 5)

        await play(rig, [(.incorrect, "easy")])
        #expect(rig.vm.resultStreak == nil, "a miss shows no run")
        await play(rig, [(.correct, "easy"), (.correct, "easy")])
        #expect(rig.vm.resultStreak == nil, "a miss ends the run")
        await play(rig, [(.correct, "easy")])
        #expect(rig.vm.resultStreak == 3)
    }

    @Test("the verdict label carries the run beside \"Correct\"")
    func verdictLabelShowsTheRun() throws {
        let withRun = ResultVerdictLabel(verdict: .correct, streak: 3)
        #expect(throws: Never.self) { try withRun.inspect().find(viewWithAccessibilityIdentifier: "result.streak") }
        let plain = ResultVerdictLabel(verdict: .correct)
        #expect(throws: (any Error).self) { try plain.inspect().find(viewWithAccessibilityIdentifier: "result.streak") }
    }

    /// WHY: the end of the round was only a list. It opens with one line worth
    /// remembering: the best run if there was one, else the hardest question
    /// answered right (the later one on a tie), else a calm line that the
    /// answers are below.
    @Test("the end of the round opens with the best run, else the hardest right answer")
    func roundHighlightRules() async {
        let empty = makeRig(clock: TestClock())
        #expect(empty.vm.roundHighlight == nil)

        let run = makeRig(clock: TestClock())
        await play(run, [(.correct, "easy"), (.incorrect, "hard"), (.correct, "easy"), (.correct, "easy"), (.correct, "hard"), (.skipped, "easy")])
        #expect(run.vm.roundHighlight == .bestRun(3))

        let hardest = makeRig(clock: TestClock())
        await play(hardest, [(.correct, "hard"), (.incorrect, "easy"), (.correct, "medium"), (.incorrect, "easy"), (.correct, "hard"), (.skipped, "hard")])
        #expect(hardest.vm.roundHighlight == .hardestRight(answer: "Answer 5"))

        let none = makeRig(clock: TestClock())
        await play(none, [(.incorrect, "easy"), (.skipped, "hard")])
        #expect(none.vm.roundHighlight == .noneRight)
    }

    @Test("the end-of-round screen shows the line above its list")
    func roundCompleteShowsTheHighlight() async throws {
        let rig = makeRig(clock: TestClock())
        await play(rig, [(.correct, "easy"), (.correct, "easy"), (.correct, "easy")])
        rig.vm.quizState = .finished
        let view = CompletionView(viewModel: rig.vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "completion.highlight") }
        }
    }

    // MARK: - Item 7: the monthly limit reached on an answer

    private func limit(with evaluation: Evaluation?) -> QuotaLimitError {
        QuotaLimitError(
            error: "quota_limit_reached", questionsUsed: 30, questionsLimit: 30,
            resetsAt: "2026-12-01T00:00:00Z", upgradeAvailable: false, evaluation: evaluation
        )
    }

    @Test("the 429 body's verdict decodes (server sends it snake_case)")
    func quotaErrorDecodesTheVerdict() throws {
        let json = """
        {"error":"quota_limit_reached","questions_used":30,"questions_limit":30,"resets_at":"2026-12-01T00:00:00Z","upgrade_available":true,
         "evaluation":{"user_answer":"Paris","result":"correct","points":1.0,"correct_answer":"Paris","question_id":"q_001","explanation":null}}
        """
        let decoded = try JSONDecoder().decode(QuotaLimitError.self, from: Data(json.utf8))
        #expect(decoded.evaluation?.isCorrect == true)
        let start = try JSONDecoder().decode(QuotaLimitError.self, from: Data("""
        {"error":"quota_limit_reached","questions_used":30,"questions_limit":30,"resets_at":"2026-12-01T00:00:00Z","upgrade_available":true}
        """.utf8))
        #expect(start.evaluation == nil, "the start gate carries no verdict")
    }

    /// WHY: the last answer of the month was graded and scored by the server,
    /// but the app showed only the paywall: no verdict, no round score. Now
    /// the verdict shows (and counts), the round ends on its own screen, and
    /// the paywall follows a moment later.
    @Test("limit reached on an answer: its verdict, then the end of the round, then the paywall")
    func quotaShowsVerdictThenRoundEndThenPaywall() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.vm.settings.isMuted = true
        rig.vm.quizState = .processing

        await rig.vm.handleError(
            NetworkError.quotaLimitReached(limit(with: evaluation(.correct))),
            context: .submission, fallbackMessage: "Failed to submit answer"
        )

        #expect(rig.vm.resultEvaluation?.isCorrect == true, "the last answer's verdict shows")
        #expect(!rig.vm.showPaywall, "the paywall waits for the end of the round")
        #expect(rig.vm.score == 1, "the answer the server scored counts in the round")
        #expect(rig.vm.recapEntries.count == 1)

        _ = await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(rig.vm.settings.autoAdvanceDelay + 2), {
            rig.vm.quizState == .finished
        }, "the round never ended after the last verdict")
        #expect(!rig.vm.showPaywall, "the paywall covered the end of the round at once")

        await clock.advance(by: .milliseconds(Config.roundEndPaywallDelay * 1000 - 200))
        #expect(!rig.vm.showPaywall)
        _ = await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(2), {
            rig.vm.showPaywall
        }, "the paywall never followed the end of the round")
        #expect(rig.vm.quotaLimitError?.questionsLimit == 30)
        #expect(rig.vm.quizState == .finished, "closing the paywall lands on the end of the round")
        #expect(rig.analytics.events(named: "paywall_viewed").count == 1)
    }

    /// WHY: leaving the end of the round before the paywall shows (Home)
    /// must not throw the paywall over Home a moment later.
    @Test("leaving the end of the round first cancels the paywall")
    func leavingTheRoundEndCancelsThePaywall() async {
        let clock = TestClock()
        let rig = makeRig(clock: clock)
        rig.vm.settings.isMuted = true
        rig.vm.quizState = .processing
        await rig.vm.handleError(
            NetworkError.quotaLimitReached(limit(with: evaluation(.incorrect))),
            context: .submission, fallbackMessage: "Failed to submit answer"
        )
        _ = await advanceUntil(clock, step: .milliseconds(100), limit: .seconds(rig.vm.settings.autoAdvanceDelay + 2), {
            rig.vm.quizState == .finished
        }, "the round never ended after the last verdict")
        rig.vm.resetToHome()
        await clock.advance(by: .seconds(Config.roundEndPaywallDelay + 2))
        #expect(!rig.vm.showPaywall)
    }

    /// WHY: an older server (or the start gate) sends no verdict; that keeps
    /// today's path: the paywall at once, the quiz back to idle.
    @Test("a 429 without a verdict keeps the plain paywall")
    func quotaWithoutVerdictKeepsThePlainPaywall() async {
        let rig = makeRig(clock: TestClock())
        rig.vm.settings.isMuted = true
        rig.vm.quizState = .processing
        await rig.vm.handleError(
            NetworkError.quotaLimitReached(limit(with: nil)),
            context: .submission, fallbackMessage: "Failed to submit answer"
        )
        #expect(rig.vm.showPaywall)
        #expect(rig.vm.quizState == .idle)
        #expect(rig.vm.recapEntries.isEmpty)
    }
}
