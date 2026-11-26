//
//  RoomDraftTimeoutTests.swift
//  HangsTests
//
//  #249.3: a typed but unsent answer is sent when the shared answer time runs
//  out (the server still takes answers for a 2 s grace). Time is the injected
//  clock; the mock room answers after the deadline too, so a late arrival is
//  only judged by what the phone did, not by the mock.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("A typed answer is sent when the time runs out (#249.3)")
@MainActor
struct RoomDraftTimeoutTests {
    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let audio = MockAudioService()
    private let clock = TestClock<Duration>()

    /// Answers sent on the typed question (the first, tapped one is skipped).
    private var typedSent: [String] { Array(rooms.answers.dropFirst()) }

    /// Lets scheduled work run without moving the clock; nothing is awaited that may never come.
    private func settle() async {
        for _ in 0 ..< 100 { await Task.yield() }
    }

    /// A guest at the typed second question (20 s of answer time from now).
    private func guestAtTypedQuestion() async -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        rooms.conditions.networkClock = AnyClock(clock)
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: .default, deviceId: "device",
            accountName: "Michal Kalis",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-draft-\(UUID().uuidString)")!),
            settingsStore: MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-draft-rules-\(UUID().uuidString)")!),
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true },
            pendingLeaves: PendingRoomLeaveStore(defaults: UserDefaults(suiteName: "room-draft-leave-\(UUID().uuidString)")!)
        )
        await model.join(.token(MockRoomService.token))
        rooms.hostStarts()
        await model.refresh()
        await model.guestReadTask?.value
        await model.submitOption(key: "b")
        rooms.hostMovesOn()
        await model.refresh()
        await model.guestReadTask?.value
        #expect(model.question?.id == "mq2")
        #expect(model.canAnswer)
        return model
    }

    // WHY: a player who typed the answer and ran out of time loses the point
    // for nothing; the phone sends the text itself, trimmed, when the clock hits zero.
    @Test("the typed text is sent once at zero, not before")
    func draftSentAtTimeout() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        model.typedAnswer = "  Canberra "

        await clock.advance(by: .milliseconds(19900))
        await settle()
        #expect(typedSent.isEmpty, "the draft was sent before the time ran out")
        await clock.advance(by: .milliseconds(200))
        await pumpUntil { typedSent.count == 1 }
        #expect(typedSent == ["Canberra"])
    }

    // WHY: nothing typed means nothing to send; an empty answer would count
    // as a wrong guess instead of "no answer".
    @Test("an empty or blank draft sends nothing", arguments: ["", "   \n"])
    func blankDraftNotSent(draft: String) async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        model.typedAnswer = draft

        await clock.advance(by: .seconds(25))
        await settle()
        #expect(typedSent.isEmpty)
    }

    // WHY: tapping send at the very end must not also fire the timeout
    // send: one player, one answer.
    @Test("send tapped just before the timeout gives exactly one submission")
    func tapRacingTimeout() async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        model.typedAnswer = "Canberra"
        let hold = rooms.conditions.hold(.answer)
        await clock.advance(by: .seconds(19))
        let tap = Task { await model.submitTypedAnswer() }
        await pumpUntil { hold.heldCount == 1 }

        await clock.advance(by: .seconds(2))
        await settle()
        #expect(hold.arrivals == 1, "the timeout sent a second answer while the tap was in flight")
        hold.release()
        await tap.value
        #expect(typedSent == ["Canberra"])
        await clock.advance(by: .seconds(5))
        await settle()
        #expect(typedSent == ["Canberra"], "an answered question was sent again at the timeout")
    }

    // WHY: when the auto-send is refused (time up, no network) the player must
    // see the ordinary "Time's up" state, no spinner, no error that blocks the
    // screen, and the game must go on to the reveal.
    @Test("a failed auto-send leaves the normal timed-out state and the game goes on", arguments: [
        NetworkCondition.serverError(statusCode: 409), .serverError(statusCode: 500), .offline, .malformed,
    ])
    func failedAutoSend(condition: NetworkCondition) async {
        let model = await guestAtTypedQuestion()
        defer { model.stopAll() }
        model.typedAnswer = "Canberra"
        rooms.conditions.setNetworkCondition(condition, for: [.answer])

        await clock.advance(by: .seconds(21))
        await settle()

        #expect(model.submittingAnswer == nil, "the answer field spins forever")
        #expect(model.errorMessage == nil, "a blocking error replaced the Time's up screen")
        #expect(model.secondsLeft() == 0)
        #expect(!model.canAnswer)
        #expect(model.screen == .question)
        rooms.conditions.setNetworkCondition(nil, for: [.answer])
        rooms.othersAnswer()
        await model.refresh()
        #expect(model.screen == .reveal, "the player cannot continue after a failed auto-send")
    }
}
