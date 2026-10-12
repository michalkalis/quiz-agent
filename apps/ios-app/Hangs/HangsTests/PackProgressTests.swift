//
//  PackProgressTests.swift
//  HangsTests
//
//  #200 (founder TF test 2026-10-12). Why these tests matter:
//  - "Play Again" after a custom pack started the shared library ("Zábava")
//    instead of the pack, and so did "Try again" and the spoken "znova". Every
//    again path must replay the pack the player chose, including a start that
//    failed before its session existed.
//  - A pack remembers which of its questions this phone played: each play
//    continues with the next unplayed ones, a question counts once it is on
//    screen (not when prefetched), and pack questions stay out of the global
//    history, whose reset must not rewind a pack.
//  - A pack played through asks before starting over instead of failing with
//    a raw server error; the server's "nothing left" is only a safety net.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
@Suite("Custom pack progress and replay (#200)")
struct PackProgressTests {
    private let pack = PackPlay(packId: "pack-1", questionCount: 3)

    private struct Rig {
        let vm: QuizViewModel
        let network: MockNetworkService
        let store: MockPersistenceStore
        let silence: MockSilenceDetectionService
    }

    private func makeRig() -> Rig {
        let network = Fixtures.makeFullMockNetwork()
        let store = MockPersistenceStore()
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: store,
            silenceDetectionService: silence,
            sttService: nil,
            clock: AnyClock(TestClock())
        )
        return Rig(vm: vm, network: network, store: store, silence: silence)
    }

    private func nextQuestionResponse(_ id: String) -> QuizResponse {
        QuizResponse(
            success: true,
            message: "Input processed",
            session: Fixtures.makeActiveSession(),
            currentQuestion: Fixtures.makeQuestion(id: id),
            evaluation: Evaluation(
                userAnswer: "4", result: .correct, points: 1, correctAnswer: "4",
                questionId: "q_002", explanation: nil
            ),
            feedbackReceived: [],
            audio: nil
        )
    }

    // MARK: - Ledger

    @Test("a pack start excludes only that pack's played questions and keeps them out of the global history")
    func packStartUsesItsOwnLedger() async {
        let rig = makeRig()
        rig.store.askedQuestionIds = ["lib_1"]
        rig.store.playedPackQuestions = ["pack-1": ["p_1"], "pack-2": ["other"]]

        await rig.vm.startNewQuiz(pack: pack)

        #expect(rig.network.capturedPackId == "pack-1")
        #expect(rig.network.capturedStartQuizExcludedIds == ["p_1"],
                "the library history would hide pack questions, and another pack's ledger says nothing about this one")
        #expect(rig.store.playedPackQuestionIds(packId: "pack-1") == ["p_1", "q_002"], "the first question is on screen")
        #expect(rig.store.askedQuestionIds == ["lib_1"], "a pack question must not enter the global history")
    }

    @Test("a library start still excludes and records the global history, not a pack ledger")
    func libraryStartUsesGlobalHistory() async {
        let rig = makeRig()
        rig.store.askedQuestionIds = ["lib_1"]
        rig.store.playedPackQuestions = ["pack-1": ["p_1"]]

        await rig.vm.startNewQuiz()

        #expect(rig.network.capturedStartQuizExcludedIds == ["lib_1"])
        #expect(rig.store.askedQuestionIds == ["lib_1", "q_002"])
        #expect(rig.store.playedPackQuestionIds(packId: "pack-1") == ["p_1"])
    }

    /// WHY: the next question arrives with the verdict, before it is shown. A
    /// set left on the result screen must not burn that question of the pack.
    @Test("a pack question counts as played when shown, not when prefetched")
    func countsOnScreenNotAtPrefetch() async {
        let rig = makeRig()
        await rig.vm.startNewQuiz(pack: pack)
        rig.vm.quizState = .processing

        await rig.vm.handleQuizResponse(nextQuestionResponse("q_003"))
        #expect(rig.store.playedPackQuestionIds(packId: "pack-1") == ["q_002"], "prefetched, not yet shown")

        await rig.vm.proceedToNextQuestion()
        #expect(rig.store.playedPackQuestionIds(packId: "pack-1") == ["q_002", "q_003"])
        #expect(rig.store.askedQuestionIds.isEmpty)
    }

    // MARK: - Again paths

    @Test("Play Again after a pack replays the same pack")
    func playAgainReplaysPack() async {
        let rig = makeRig()
        await rig.vm.startNewQuiz(pack: pack)
        rig.vm.quizState = .finished

        await rig.vm.playAgain().value

        #expect(rig.network.createSessionCallCount == 2)
        #expect(rig.network.capturedPackId == "pack-1", "Play Again started the shared library (the TF bug)")
    }

    /// WHY (TF finding 12): a pack start that failed on a cold server offered
    /// Try again, which then started the library. The pack is known from the
    /// request, before any session exists.
    @Test("Try again after a failed pack start retries the same pack, by tap and by voice")
    func retryAfterFailedStartKeepsPack() async {
        let rig = makeRig()
        rig.network.createSessionError = NetworkError.serverError(statusCode: 500, message: "connection closed")
        await rig.vm.startNewQuiz(pack: pack)
        #expect(rig.vm.shouldRetryWithNewSession)
        rig.network.createSessionError = nil

        await rig.vm.retryFromErrorScreen().value
        #expect(rig.network.capturedPackId == "pack-1")

        rig.network.capturedPackId = nil
        rig.vm.quizState = .finished
        rig.network.createSessionError = NetworkError.serverError(statusCode: 500, message: "connection closed")
        await rig.vm.playAgain().value
        rig.network.createSessionError = nil
        await rig.vm.retryFromErrorByVoice()
        await pumpUntil({ rig.vm.quizState == .askingQuestion }, "spoken 'znova' never restarted")
        #expect(rig.network.capturedPackId == "pack-1")
    }

    @Test("spoken 'znova' at the end of a pack replays the pack")
    func spokenAgainAtSetEndReplaysPack() async {
        let rig = makeRig()
        await rig.vm.startNewQuiz(pack: pack)
        rig.vm.quizState = .processing
        await rig.vm.handleError(NetworkError.sessionFinished, context: .submission, fallbackMessage: "x")
        #expect(rig.vm.quizState == .finished)
        await pumpUntil({ rig.silence.isListening && rig.vm.voiceCommandCoordinator.currentCommandScreen == .setEnd },
                        "the score screen never listened")

        let language = CommandLanguage.forQuizLanguage(rig.vm.currentSession?.language ?? rig.vm.settings.language)
        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.again, language: language))

        await pumpUntil({ rig.network.createSessionCallCount == 2 }, "'znova' did not start again")
        #expect(rig.network.capturedPackId == "pack-1")
    }

    // MARK: - Played through

    @Test("a played-through pack asks before starting, and nothing starts until it is answered")
    func playedThroughAsks() async {
        let rig = makeRig()
        rig.store.playedPackQuestions = ["pack-1": ["p_1", "p_2", "p_3"]]
        rig.vm.quizState = .finished

        await rig.vm.startNewQuiz(pack: pack)

        #expect(rig.vm.packRestartOffer == pack)
        #expect(rig.network.createSessionCallCount == 0)
        #expect(rig.vm.quizState == .finished, "Cancel must leave the player on the screen they were on")
    }

    @Test("Start over forgets the pack's progress and plays it from the top")
    func startOverClearsAndStarts() async {
        let rig = makeRig()
        rig.store.askedQuestionIds = ["lib_1"]
        rig.store.playedPackQuestions = ["pack-1": ["p_1", "p_2", "p_3"]]
        await rig.vm.startNewQuiz(pack: pack)

        await rig.vm.restartPack(pack).value

        #expect(rig.vm.packRestartOffer == nil)
        #expect(rig.network.capturedStartQuizExcludedIds == [])
        #expect(rig.store.playedPackQuestionIds(packId: "pack-1") == ["q_002"])
        #expect(rig.store.askedQuestionIds == ["lib_1"], "starting a pack over leaves the library history")
    }

    @Test("a pack still being generated never asks, however much was played")
    func growingPackNeverAsks() async {
        let rig = makeRig()
        rig.store.playedPackQuestions = ["pack-1": ["p_1", "p_2", "p_3"]]

        await rig.vm.startNewQuiz(pack: PackPlay(packId: "pack-1", questionCount: nil))

        #expect(rig.vm.packRestartOffer == nil)
        #expect(rig.network.createSessionCallCount == 1)
    }

    /// WHY: the phone's count can be off (a question the server will not serve).
    /// The server's `pack_exhausted` then gets the same offer, never the raw
    /// server error the founder saw after finishing a pack.
    @Test("the server running out of a started pack offers the restart instead of an error")
    func serverRunOutOffersRestart() async {
        let rig = makeRig()
        rig.store.playedPackQuestions = ["pack-1": ["p_1"]]
        rig.network.startQuizError = NetworkError.packExhausted

        await rig.vm.startNewQuiz(pack: PackPlay(packId: "pack-1", questionCount: 30))

        #expect(rig.vm.packRestartOffer?.packId == "pack-1")
        #expect(rig.vm.quizState == .idle)
        #expect(rig.vm.activeErrorModel == nil)
        #expect(rig.vm.currentSession == nil, "the empty session must not linger behind Home")
    }

    @Test("with nothing played here, the server's empty answer stays an error")
    func serverRunOutWithoutProgressIsAnError() async {
        let rig = makeRig()
        rig.network.startQuizError = NetworkError.packExhausted

        await rig.vm.startNewQuiz(pack: pack)

        #expect(rig.vm.packRestartOffer == nil, "a restart cannot help a pack nothing was played of")
        #expect(rig.vm.activeErrorModel != nil)
    }
}

// MARK: - Wire contract

@Suite("#200 — pack_exhausted wire contract", .serialized)
struct PackExhaustedWireContractTests {
    /// WHY: decoded as a generic 409 the end of a pack read as a server fault
    /// with a Try again that fails forever. It must reach the app as its own
    /// error so the start can offer the pack again.
    @Test("a coded pack_exhausted 409 on start → .packExhausted")
    func codedPackExhaustedDecodes() async {
        let body = #"{"detail":{"code":"pack_exhausted","message":"Every question in this pack has been played","pack_id":"p1"}}"#
        StubURLProtocol.handler = { _ in (.make(status: 409), Data(body.utf8)) }
        defer { StubURLProtocol.handler = nil }
        let service = NetworkService(baseURL: "http://test.invalid", session: StubURLProtocol.makeSession())

        do {
            _ = try await service.startQuiz(sessionId: "s1", excludedQuestionIds: ["q1"])
            Issue.record("expected a throw")
        } catch NetworkError.packExhausted {
            // expected
        } catch {
            Issue.record("expected .packExhausted, got \(error)")
        }
    }
}
