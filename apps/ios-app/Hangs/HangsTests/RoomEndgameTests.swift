//
//  RoomEndgameTests.swift
//  HangsTests
//
//  #240.9 (founder 2026-11-18): the end of a game together. Why it matters:
//  "Play again" is only worth a tap if the same people land in the new game
//  without being invited again, so the host's room moves (same id and link)
//  and every guest's phone, still polling, follows into the lobby; the host
//  must see progress while it is on its way and an error with a way out when
//  it fails. Changing what the room plays must keep the guests and the link
//  the host already sent. The awards and the ranking picture give more than
//  the winner a moment, and every new step is measured.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Game together: play again, awards, sharing (#240.9)")
@MainActor
struct RoomEndgameTests {
    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let analytics = MockAnalyticsClient()
    private let clock = TestClock<Duration>()

    private func makeModel(packs: Bool = false) -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        rooms.conditions.networkClock = AnyClock(clock)
        let store = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "endgame-rules-\(UUID().uuidString)")!)
        return RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "device",
            accountName: "Michal",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "endgame-names-\(UUID().uuidString)")!),
            settingsStore: store, analytics: analytics, clock: AnyClock(clock), languageCode: "sk",
            isOffCellular: { true }, packsEnabled: { packs },
            pendingLeaves: PendingRoomLeaveStore(defaults: UserDefaults(suiteName: "endgame-leave-\(UUID().uuidString)")!)
        )
    }

    private func hostFinished() async -> RoomViewModel {
        let model = makeModel()
        await model.beginHosting()
        await model.startGame()
        await model.readTask?.value
        await model.submitOption(key: "b")
        await model.next()
        await model.readTask?.value
        model.typedAnswer = "Canberra"
        await model.submitTypedAnswer()
        await model.next()
        return model
    }

    private func guestFinished() async -> RoomViewModel {
        let model = makeModel()
        await model.join(.qr(MockRoomService.token))
        rooms.hostStarts()
        await model.refresh()
        await model.submitOption(key: "b")
        rooms.hostMovesOn()
        await model.refresh()
        model.typedAnswer = "Sydney"
        await model.submitTypedAnswer()
        rooms.hostMovesOn()
        await model.refresh()
        return model
    }

    private var closes: [AnalyticsEvent] {
        analytics.events.filter { if case .roomClosed = $0 { true } else { false } }
    }

    // MARK: - Play again

    @Test("Play again keeps the room and everyone in it, and the new game skips the last game's questions")
    func playAgainKeepsEveryone() async {
        let model = await hostFinished()
        defer { model.stopAll() }
        #expect(model.screen == .finished)
        #expect(model.canPlayAgain)

        await model.playAgain()

        #expect(rooms.moves == [nil, MockRoomService.roomId], "the host's room must move, not a new one be made")
        #expect(model.created?.roomId == MockRoomService.roomId, "the link and QR the guests have stay valid")
        #expect(model.screen == .lobby)
        #expect(model.players.map(\.displayName) == ["Michal", "Jana"])
        #expect(model.players.allSatisfy { $0.score == 0 })
        #expect(closes == [.roomClosed(reason: .finished, players: 2, questions: 2)])

        await model.startGame()
        #expect(network.capturedStartQuizExcludedIds == ["mq1", "mq2"], "the same questions would come again")
    }

    @Test("A guest on the final ranking follows the host into the new game by itself")
    func guestFollowsPlayAgain() async {
        let model = await guestFinished()
        defer { model.stopAll() }
        #expect(model.screen == .finished)
        #expect(!model.canPlayAgain, "only the host starts another game")

        rooms.hostPlaysAgain()
        await advanceUntil(clock, limit: .seconds(5)) { model.screen == .lobby }
        #expect(model.players.count == 2)
    }

    @Test("A finished game whose room is gone keeps its ranking on screen")
    func finishedRoomGoneKeepsRanking() async {
        let model = await guestFinished()
        defer { model.stopAll() }
        rooms.stateError = NetworkError.serverError(statusCode: 404, message: "gone")
        await model.refresh()
        #expect(model.screen == .finished)
        #expect(!model.rankRows.isEmpty)
    }

    @Test("A slow play again shows progress and Done still leaves; the late reply leaves nobody in a lobby without a host")
    func slowPlayAgain() async {
        let model = await hostFinished()
        defer { model.stopAll() }
        let hold = rooms.conditions.hold(.createRoom)
        let again = Task { await model.playAgain() }
        await pumpUntil { hold.heldCount == 1 }

        #expect(model.isWorking, "no progress while the new game is on its way")
        #expect(model.screen == .finished)
        let ended = network.endSessionCallCount
        await model.leave()
        hold.release()
        await again.value

        #expect(network.endSessionCallCount == ended + 1, "the moved room would wait for a host who left")
        #expect(model.errorMessage == nil)
    }

    @Test("A failed play again says so and keeps the ranking with Done", arguments: RoomConditionTests.failures)
    func failedPlayAgain(condition: NetworkCondition) async {
        let model = await hostFinished()
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(condition, for: [.createRoom])
        let again = Task { await model.playAgain() }

        await advanceUntil(clock, limit: .seconds(60)) { model.errorMessage != nil }
        await again.value

        #expect(model.screen == .finished)
        #expect(!model.isWorking)
        #expect(model.canPlayAgain, "the host can try again")
        #expect(closes.isEmpty, "the game was not replaced")
    }

    @Test("No play again when the host's free questions ran out")
    func noPlayAgainWithoutQuestions() async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }
        #expect(!model.canPlayAgain, "not before the end")
    }

    // MARK: - What we play

    @Test("Other content after a guest joined keeps the room, the guest and the link")
    func contentChangeKeepsGuests() async {
        let model = makeModel(packs: true)
        await model.beginHosting()
        defer { model.stopAll() }
        #expect(model.canChangeContent, "a guest in the lobby no longer locks the content")

        await model.play(.pack(id: "p1", title: "Bridges"))

        #expect(rooms.moves == [nil, MockRoomService.roomId])
        #expect(network.capturedPackId == "p1")
        #expect(model.created?.roomId == MockRoomService.roomId)
        #expect(model.players.map(\.displayName) == ["Michal", "Jana"])
        #expect(model.content == .pack(id: "p1", title: "Bridges"))
    }

    @Test("A slow content change keeps the lobby and shows progress; a failed one goes back", arguments: RoomConditionTests.failures)
    func slowAndFailedContentChange(condition: NetworkCondition) async {
        let model = makeModel(packs: true)
        await model.beginHosting()
        defer { model.stopAll() }
        let hold = rooms.conditions.hold(.createRoom)
        let change = Task { await model.play(.pack(id: "p1", title: "Bridges")) }
        await pumpUntil { hold.heldCount == 1 }
        #expect(model.isWorking)
        #expect(model.screen == .lobby)
        #expect(model.players.count == 2)

        rooms.conditions.setNetworkCondition(condition, for: [.createRoom])
        hold.release()
        await advanceUntil(clock, limit: .seconds(60)) { model.errorMessage != nil }
        await change.value

        #expect(model.content == .categories, "the host must see what the room still plays")
        #expect(model.screen == .lobby)
        #expect(!model.isWorking)
    }

    // MARK: - Awards and sharing

    @Test("Awards name players still in the room; a kind this build does not know is skipped")
    func awardRows() async {
        rooms.awards?.append(RoomState.Award(kind: "mystery", participantId: MockRoomService.youId))
        let model = await hostFinished()
        defer { model.stopAll() }

        let rows = model.awardRows
        #expect(rows.map(\.kind) == [.fastest, .onlyOne])
        #expect(rows[0].name == "Jana", "the fastest answer is not the winner's, so Jana gets a moment")
        #expect(rows[0].seconds == 2.3)
        #expect(rows[0].questionNumber == 1)
        #expect(rows[1].isYou)
    }

    @Test("Opening the share sheet on the ranking is measured with the role")
    func rankingShared() async {
        let model = await guestFinished()
        defer { model.stopAll() }
        model.rankingShared()
        #expect(analytics.events.contains(.roomRankingShared(role: "guest", players: 2)))
    }

    // MARK: - How a game closed

    @Test("The host's phone reports once how the game closed", arguments: [
        RoomCloseReason.neverStarted, .hostLeft, .expired,
    ])
    func closeReasons(reason: RoomCloseReason) async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }
        if reason != .neverStarted {
            await model.startGame()
            await model.readTask?.value
        }
        if reason == .expired {
            rooms.stateError = NetworkError.serverError(statusCode: 404, message: "gone")
            await model.refresh()
            #expect(model.screen == .ended)
        }
        await model.leave()

        #expect(closes == [.roomClosed(reason: reason, players: 2, questions: reason == .neverStarted ? 0 : 1)])
    }

    @Test("Leaving the final ranking closes the game as finished; a guest reports nothing")
    func finishedClose() async {
        let host = await hostFinished()
        await host.leave()
        #expect(closes == [.roomClosed(reason: .finished, players: 2, questions: 2)])

        let guest = await guestFinished()
        await guest.leave()
        #expect(closes.count == 1)
    }
}
