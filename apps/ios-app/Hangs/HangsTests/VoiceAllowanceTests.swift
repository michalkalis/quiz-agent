//
//  VoiceAllowanceTests.swift
//  HangsTests
//
//  Free tier split (founder experiment 2026-11-21): a free player gets 150
//  questions a month, at most 30 of them by voice. Decision D1: when the
//  voice answers run out the app says so ONCE, the quiz goes on by typing and
//  tapping, and for the rest of the month the voice control never keeps
//  failing. The rules guarded here: the question in progress stays answerable,
//  the refusal is never retried or looped, the notice comes once a month, and
//  a new month (or Plus) gives voice back.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

nonisolated let voiceTestResetsAt = "2026-12-01T00:00:00+00:00"
nonisolated let voiceTestRefusal = VoiceLimitError(
    code: VoiceLimitError.reachedCode, voiceAnswersUsed: 30, voiceAnswersLimit: 30, resetsAt: voiceTestResetsAt
)

nonisolated func voiceTestUsage(voiceRemaining: Int?, voiceLimit: Int? = 30, resetsAt: String = voiceTestResetsAt, status: String = "none") -> UsageInfo {
    UsageInfo(
        userId: "u1", isPremium: false, questionsUsed: 40, questionsLimit: 150, remaining: 110,
        resetsAt: voiceTestResetsAt, subscriptionStatus: status, creditBalance: 0,
        voiceAnswersUsed: voiceLimit.map { $0 - (voiceRemaining ?? 0) } ?? 12,
        voiceAnswersLimit: voiceLimit, voiceAnswersRemaining: voiceRemaining
    )
}

@Suite("Free voice answers used up (2026-11-21)")
@MainActor
struct VoiceAllowanceTests {
    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let store: MockPersistenceStore
        let analytics: MockAnalyticsClient
        let clock: TestClock<Duration>
    }

    private func makeRig(store: MockPersistenceStore = MockPersistenceStore()) -> Rig {
        let clock = TestClock()
        let network = Fixtures.makeFullMockNetwork()
        network.networkClock = AnyClock(clock)
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: store,
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(clock),
            analytics: analytics
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .askingQuestion
        return Rig(vm: vm, network: network, store: store, analytics: analytics, clock: clock)
    }

    /// Record and stop: what a voice answer does on the question screen.
    private func answerByVoice(_ vm: QuizViewModel) async {
        await vm.toggleRecording()
        vm.mockSilence?.simulateAnswerAudio(Data(count: 32000))
        await vm.toggleRecording()
    }

    private func refuseVoice(_ rig: Rig) async {
        rig.network.submitVoiceAnswerError = NetworkError.voiceLimitReached(voiceTestRefusal)
        await answerByVoice(rig.vm)
        await pumpUntil({ rig.vm.quizState == .askingQuestion }, "the refused answer did not return to the question")
    }

    // WHY: D1, the question in progress stays on screen and answerable. The
    // refusal charged nothing, so typing the answer must grade it normally,
    // with one voice upload and one typed submit (never a second charge).
    @Test("the refused voice answer returns to the same question, which a typed answer then grades")
    func refusalKeepsQuestionAnswerable() async {
        let rig = makeRig()
        await refuseVoice(rig)

        #expect(rig.vm.currentQuestion?.id == "q_001")
        #expect(rig.vm.activeErrorModel == nil, "a used-up allowance is no error screen")
        #expect(rig.vm.showsVoiceLimitNotice)
        #expect(rig.vm.showPaywall == false, "never a hard paywall over the question")

        await rig.vm.resubmitAnswer("4")

        #expect(rig.vm.quizState.isShowingResult)
        #expect(rig.network.submitVoiceAnswerCallCount == 1, "the refusal was retried")
        #expect(rig.network.submitTextInputCallCount == 1)
    }

    // WHY: D1, "the voice answer control must not keep failing". After the
    // refusal no think window arms and no mic opens by itself, however long
    // the player takes, so the server is never asked again.
    @Test("after the refusal no countdown and no mic opens by itself")
    func noAutoMicLoop() async {
        let rig = makeRig()
        await refuseVoice(rig)

        rig.vm.startRecordingOrTimer()
        #expect(rig.vm.thinkingTimeCountdown == 0, "a countdown towards a mic that cannot be used")
        await rig.clock.advance(by: .seconds(120))

        #expect(rig.vm.quizState == .askingQuestion)
        #expect(rig.network.submitVoiceAnswerCallCount == 1)
    }

    // WHY: said ONCE. The next question's Answer tap or "answer" must neither
    // open the mic nor repeat the notice, the line or the event.
    @Test("the notice, the spoken line and the event come once; later questions stay quiet")
    func noticeComesOnce() async {
        let rig = makeRig()
        await refuseVoice(rig)
        await pumpUntil { rig.network.synthesizedTexts.count == 1 }

        rig.vm.currentQuestion = Fixtures.makeQuestion(id: "q_002")
        await rig.vm.toggleRecording()
        rig.vm.startRecordingOrTimer()

        #expect(rig.vm.quizState == .askingQuestion, "the mic opened on a spent allowance")
        #expect(rig.vm.showsVoiceLimitNotice == false)
        #expect(rig.analytics.events(named: "voice_limit_notice_shown") == [.voiceLimitNoticeShown])
        #expect(rig.network.synthesizedTexts == [SpokenPrompt.voiceLimitLine(language: .english)])
        #expect(rig.network.submitVoiceAnswerCallCount == 1)
    }

    // WHY: once a MONTH, also across launches: a phone that already showed it
    // this month starts the next quiz silently on typing and tapping.
    @Test("a month that already had the notice starts the next quiz without it")
    func noticeOncePerMonthAcrossLaunches() {
        let store = MockPersistenceStore()
        store.setVoiceLimitNoticeMonth(voiceTestResetsAt)
        let rig = makeRig(store: store)
        rig.vm.usageInfo = voiceTestUsage(voiceRemaining: 0)

        rig.vm.startRecordingOrTimer()

        #expect(rig.vm.thinkingTimeCountdown == 0)
        #expect(rig.vm.showsVoiceLimitNotice == false)
        #expect(rig.analytics.events(named: "voice_limit_notice_shown").isEmpty)
    }

    // WHY: when /usage already says none is left (the 30th voice answer was
    // the last), the player is told on the first question instead of meeting
    // a refusal, and the mic is never opened.
    @Test("usage reporting no voice answers left: told on the first question, the mic never opens")
    func usageSpentTellsWithoutRefusal() async {
        let rig = makeRig()
        rig.vm.usageInfo = voiceTestUsage(voiceRemaining: 0)

        rig.vm.startRecordingOrTimer()
        await rig.clock.advance(by: .seconds(60))

        #expect(rig.vm.showsVoiceLimitNotice)
        #expect(rig.store.voiceLimitNoticeMonth == voiceTestResetsAt)
        #expect(rig.vm.quizState == .askingQuestion)
        #expect(rig.network.submitVoiceAnswerCallCount == 0)
    }

    // WHY: subscribers and pack-credit holders are never limited; their usage
    // has null voice fields and the mic must work as before.
    @Test("unlimited voice (null fields) keeps the mic and shows no notice")
    func unlimitedKeepsVoice() async {
        let rig = makeRig()
        rig.vm.usageInfo = voiceTestUsage(voiceRemaining: nil, voiceLimit: nil, status: "active")

        await rig.vm.toggleRecording()

        #expect(rig.vm.isVoiceAllowanceSpent == false)
        #expect(rig.vm.quizState == .recording)
        #expect(rig.vm.showsVoiceLimitNotice == false)
    }

    // WHY: packs, the daily challenge, a friend's quiz and rounds with kids
    // never draw on the quota, and the server never refuses voice there
    // (`gate_voice_answer`); the same `roundLimitsVoice` covers all four.
    @Test("a quiz from a friend's link or a round with kids keeps the mic with the voice answers used up",
          arguments: ["share", "family"])
    func exemptRoundKeepsVoice(kind: String) async {
        let rig = makeRig()
        rig.vm.usageInfo = voiceTestUsage(voiceRemaining: 0)
        if kind == "share" {
            rig.vm.activeShare = SharedQuizPlay(token: "t1", kind: "round")
        } else {
            rig.vm.activeFamily = FamilyRound(band: .kids7to9, topic: "family-dinosaurs", roundSize: 8)
        }

        await rig.vm.toggleRecording()

        #expect(rig.vm.quizState == .recording)
        #expect(rig.vm.showsVoiceLimitNotice == false)
    }

    // WHY: a new month gives the voice answers back: a fresh /usage with
    // voice left lifts the refusal and the mic opens again.
    @Test("month rollover: fresh usage with voice left re-enables the mic")
    func monthRolloverReenablesVoice() async {
        let rig = makeRig()
        await refuseVoice(rig)
        rig.network.stubbedUsage = voiceTestUsage(voiceRemaining: 30, resetsAt: "2027-01-01T00:00:00+00:00")

        await rig.vm.refreshUsage()
        rig.vm.currentQuestion = Fixtures.makeQuestion(id: "q_002")
        await rig.vm.toggleRecording()

        #expect(rig.vm.isVoiceAllowanceSpent == false)
        #expect(rig.vm.quizState == .recording)
    }

    // WHY: a usage refresh that FAILS must not lift the refusal (the mic
    // would meet the 429 again) nor invent a limit for a player without one.
    @Test("a failed usage refresh keeps the refusal")
    func failedRefreshKeepsRefusal() async {
        let rig = makeRig()
        await refuseVoice(rig)
        rig.network.setNetworkCondition(.offline, for: [.getUsage])

        let refresh = Task { await rig.vm.refreshUsage() }
        await advanceUntil(rig.clock, limit: .seconds(5)) { rig.network.getUsageCallCount >= 3 }
        await refresh.value

        #expect(rig.vm.isVoiceAllowanceSpent)
    }

    // WHY: a slow refusal still shows progress, and the player can leave.
    // While the upload is held the bar is "evaluating"; once it lands the
    // player is back on the question, not on an error.
    @Test("a slow refusal shows progress and then returns to the question")
    func slowRefusal() async {
        let rig = makeRig()
        rig.network.submitVoiceAnswerError = NetworkError.voiceLimitReached(voiceTestRefusal)
        let hold = rig.network.hold(.submitVoiceAnswer)
        await rig.vm.toggleRecording()
        rig.vm.mockSilence?.simulateAnswerAudio(Data(count: 32000))
        let stop = Task { await rig.vm.toggleRecording() }
        await pumpUntil { hold.heldCount == 1 }
        #expect(rig.vm.quizState == .processing, "the player must see the answer is being checked")

        hold.release()
        await stop.value

        #expect(rig.vm.quizState == .askingQuestion)
        #expect(rig.vm.showsVoiceLimitNotice)
    }

    // WHY: the spoken line is a network call too. Held, the question must
    // stay answerable by typing; failed, the notice is still on screen.
    @Test("a held spoken line never blocks a typed answer")
    func heldSpokenLineDoesNotBlockTyping() async {
        let rig = makeRig()
        let hold = rig.network.hold(.synthesizeSpeech)
        await refuseVoice(rig)
        await pumpUntil { hold.heldCount == 1 }

        await rig.vm.resubmitAnswer("4")

        #expect(rig.vm.quizState.isShowingResult)
        hold.release()
    }

    @Test("a failed spoken line still leaves the notice on the question")
    func failedSpokenLineKeepsNotice() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        await refuseVoice(rig)
        await pumpUntil { rig.network.synthesizedTexts.count == 1 }

        #expect(rig.vm.showsVoiceLimitNotice)
        #expect(rig.vm.quizState == .askingQuestion)
    }

    // WHY: D1, the subscription offer is a quiet link that never blocks the
    // question: the paywall opens on the tap only, the question stays open.
    @Test("the Plus link opens the paywall as source voice_limit, the question stays open")
    func plusLinkOpensPaywall() async {
        let rig = makeRig()
        await refuseVoice(rig)

        rig.vm.openPaywallFromVoiceLimitNotice()

        #expect(rig.vm.showPaywall)
        #expect(rig.analytics.events(named: "paywall_viewed") == [.paywallViewed(source: .voiceLimit)])
        #expect(rig.vm.quizState == .askingQuestion)
        #expect(rig.vm.currentQuestion?.id == "q_001")
    }

    @Test("muted: the notice shows, nothing is spoken")
    func mutedSpeaksNothing() async {
        let rig = makeRig()
        rig.vm.settings.isMuted = true
        await refuseVoice(rig)

        #expect(rig.vm.showsVoiceLimitNotice)
        #expect(rig.network.synthesizedTexts.isEmpty)
    }
}
