//
//  RoomConditionTests.swift
//  HangsTests
//
//  #235.2 (flow × condition, games together row). Every phone polls the room
//  once a second, so a bad network shows up as failed polls, a join or a host
//  start that does not answer, an answer that hangs. Whatever happens the
//  player must see it (the "connection is slow" line, an error with the start
//  screen back) and must be able to leave; and once they left, a reply still
//  on its way must change nothing: no question read aloud in a closed game,
//  no player left behind in someone else's lobby. A slow poll (timeout), the
//  404 end, a refused join and the leave-app note are in RoomViewModelTests.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Games together on a bad network (#235.2)")
@MainActor
struct RoomConditionTests {
    private final class Flag {
        var value = false
    }

    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let audio = MockAudioService()
    private let clock = TestClock<Duration>()
    private let leaves = PendingRoomLeaveStore(defaults: UserDefaults(suiteName: "room-conditions-leave-\(UUID().uuidString)")!)

    private func makeModel() -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        rooms.conditions.networkClock = AnyClock(clock)
        return RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: .default, deviceId: "device",
            accountName: "Michal Kalis",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-conditions-\(UUID().uuidString)")!),
            settingsStore: MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-conditions-rules-\(UUID().uuidString)")!),
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true },
            pendingLeaves: leaves
        )
    }

    /// A guest from a link (reads aloud itself) at the first open question.
    private func guestAtFirstQuestion() async -> RoomViewModel {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        rooms.hostStarts()
        await model.refresh()
        await model.guestReadTask?.value
        return model
    }

    nonisolated static let failures: [NetworkCondition] = [
        .timeout, .offline, .dropped(after: .seconds(2)), .serverError(statusCode: 500), .malformed,
    ]

    // WHY: a guest whose phone loses the network mid-game must be told the
    // connection is shaky (not a frozen question), keep polling, and catch up
    // by itself the moment the network is back or the app returns.
    @Test("polls that keep failing show the slow-connection line, and the game catches up afterwards", arguments: [
        NetworkCondition.offline, .dropped(after: .milliseconds(500)), .serverError(statusCode: 500), .malformed,
    ])
    func failingPollsShowTroubleThenRecover(condition: NetworkCondition) async {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(condition, for: [.roomState])

        await advanceUntil(clock, limit: .seconds(10)) { model.connectionTrouble }
        #expect(model.screen == .lobby, "a shaky connection threw the player out of the game")

        rooms.conditions.setNetworkCondition(nil, for: [.roomState])
        rooms.hostStarts()
        model.appBecameActive()
        await pumpUntil { !model.connectionTrouble && model.screen == .question }
    }

    // WHY: a join that fails on the network must give the player the start
    // screen back with a message, never a lobby that waits for nothing.
    @Test("a join that fails on the network says so and gives the start screen back", arguments: failures)
    func failedJoinReturnsToStart(condition: NetworkCondition) async {
        let model = makeModel()
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(condition, for: [.joinRoom])
        let join = Task { await model.join(.token(MockRoomService.token)) }

        await advanceUntil(clock, limit: .seconds(60)) { model.errorMessage != nil }
        await join.value

        #expect(model.screen == .start)
        #expect(!model.isWorking)
    }

    // WHY: the host's "Host a game" on a dead network must end in a message
    // and the start screen, not an endless spinner.
    @Test("hosting that fails on the network says so and gives the start screen back", arguments: failures)
    func failedHostingReturnsToStart(condition: NetworkCondition) async {
        let model = makeModel()
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(condition, for: [.createRoom])
        let host = Task { await model.beginHosting() }

        await advanceUntil(clock, limit: .seconds(60)) { model.errorMessage != nil }
        await host.value

        #expect(model.screen == .start)
        #expect(model.created == nil)
        #expect(!model.isWorking)
    }

    // WHY: a slow answer spins the tapped tile and takes no second tap (one
    // player, one answer); a failed one says so and lets the player answer
    // again while the question is open, instead of silently losing the answer.
    @Test("a slow answer takes no second tap; a failed one says so and can be sent again")
    func slowAndFailedAnswer() async {
        let model = await guestAtFirstQuestion()
        defer { model.stopAll() }
        let hold = rooms.conditions.hold(.answer)
        let first = Task { await model.submitOption(key: "b") }
        await pumpUntil { hold.heldCount == 1 }

        #expect(model.submittingAnswer == "b", "the tapped tile does not show the answer is on its way")
        #expect(!model.canAnswer)
        await model.submitOption(key: "c")
        #expect(hold.arrivals == 1, "a second tap sent a second answer")
        rooms.conditions.setNetworkCondition(.offline, for: [.answer])
        hold.release()
        await first.value

        #expect(model.errorMessage != nil, "a lost answer was silent")
        #expect(model.canAnswer, "the player cannot answer again after a failed send")
        rooms.conditions.setNetworkCondition(nil, for: [.answer])
        await model.submitOption(key: "b")
        #expect(rooms.answers == ["b"])
    }

    // WHY: the player closed the game while a poll was on its way. The poll
    // stops; nothing keeps asking the server about a game the player left.
    @Test("leaving while a poll is on its way stops the polling")
    func leavingStopsPolling() async {
        let model = await guestAtFirstQuestion()
        let hold = rooms.conditions.hold(.roomState)
        await clock.advance(by: RoomViewModel.pollInterval)
        await pumpUntil { hold.heldCount == 1 }

        await model.leave()
        await pumpUntil { hold.heldCount == 0 }
        hold.release()
        await clock.advance(by: .seconds(10))

        #expect(hold.arrivals == 1, "the room was still polled after the player left")
        await pumpUntil({ rooms.removed == [MockRoomService.youId] }, "the server was never told the player left")
    }

    // WHY: a refresh started when the app came back can answer after the
    // player closed the game. Applying it would read the next question aloud
    // in a game the player already left.
    @Test("a room reply that lands after leaving changes nothing and reads nothing aloud")
    func lateReplyAfterLeavingIsIgnored() async {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        let hold = rooms.conditions.hold(.roomState)
        model.appBecameActive()
        await pumpUntil { hold.heldCount >= 1 }

        await model.leave()
        rooms.hostStarts()
        hold.release()
        await pumpUntil { hold.heldCount == 0 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(model.state?.status == .lobby, "a reply after leaving was applied")
        #expect(network.downloadedAudioPaths.isEmpty, "a question was read aloud in a game the player left")
    }

    // WHY: a guest who closed the game while the join was on its way must not
    // end up in the host's lobby as a player who never answers.
    @Test("a join that lands after leaving takes the player out of the room again")
    func lateJoinAfterLeavingIsUndone() async {
        let model = makeModel()
        let hold = rooms.conditions.hold(.joinRoom)
        let join = Task { await model.join(.token(MockRoomService.token)) }
        await pumpUntil { hold.heldCount == 1 }

        await model.leave()
        let polls = rooms.conditions.hold(.roomState)
        hold.release()
        await join.value
        await clock.advance(by: .seconds(5))

        #expect(rooms.removed == [MockRoomService.youId], "the player stayed in the room they left")
        #expect(polls.arrivals == 0, "a game the player left started polling")
    }

    // WHY: a host who closed the game while it was being created must not
    // leave an open room (and its session) behind for guests to join.
    @Test("a room created after the host left is ended at once")
    func lateRoomAfterHostLeftIsEnded() async {
        let model = makeModel()
        let hold = rooms.conditions.hold(.createRoom)
        let host = Task { await model.beginHosting() }
        await pumpUntil { hold.heldCount == 1 }

        await model.leave()
        let polls = rooms.conditions.hold(.roomState)
        hold.release()
        await host.value
        await clock.advance(by: .seconds(5))

        #expect(network.endSessionCallCount == 1, "the room the host left stays open")
        #expect(polls.arrivals == 0)
    }

    // WHY: leaving must close the game at once, whatever the network does.
    // A failure is not shown; the leave is sent again later (founder
    // 2026-11-17, F5). The close itself must never wait 30 s on it.
    @Test("leaving does not wait for a server that does not answer")
    func leaveDoesNotWaitForServer() async {
        let model = await guestAtFirstQuestion()
        rooms.conditions.setNetworkCondition(.timeout, for: [.removePlayer])
        let left = Flag()
        Task {
            await model.leave()
            left.value = true
        }

        await pumpUntil({ left.value }, "closing the game waited on the server")
        await clock.advance(by: NetworkCondition.requestTimeout)
    }

    // WHY: a guest whose leave never reached the server stayed in the host's
    // list until the host ended the game (founder 2026-11-17, F5). The leave
    // is kept and goes out the next time the Together tab opens.
    @Test("a guest's leave the server never got is sent again when the Together tab opens")
    func failedGuestLeaveIsResent() async {
        let model = await guestAtFirstQuestion()
        rooms.conditions.setNetworkCondition(.offline, for: [.removePlayer])
        await model.leave()
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        #expect(rooms.removed.isEmpty)
        #expect(leaves.load() == .guest(roomId: model.state?.roomId ?? "", participantId: MockRoomService.youId))

        rooms.conditions.setNetworkCondition(nil, for: [.removePlayer])
        makeModel().tabOpened()

        await pumpUntil({ rooms.removed == [MockRoomService.youId] }, "the kept leave was never sent again")
        await pumpUntil({ leaves.load() == nil }, "a delivered leave would be sent forever")
    }

    // WHY: a host's "end the game" that failed is sent again too; once the
    // server says the game is gone there is nothing left to tell.
    @Test("a host's end the server never got is sent again, and dropped when the game is gone")
    func failedHostEndIsResentUntilGone() async {
        let model = makeModel()
        await model.beginHosting()
        network.endSessionError = URLError(.notConnectedToInternet)
        await model.leave()
        await pumpUntil { network.endSessionCallCount == 1 }
        #expect(leaves.load() != nil, "the failed end was forgotten")

        network.endSessionError = NetworkError.sessionNotFound
        await leaves.resend(rooms: rooms, network: network)

        #expect(network.endSessionCallCount == 2)
        #expect(leaves.load() == nil, "a game the server no longer has kept being ended")
    }
}
