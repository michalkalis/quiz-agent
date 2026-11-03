//
//  RoomPauseTests.swift
//  HangsTests
//
//  #224.4 — the host stays on a reveal. Why it matters: auto-advance runs on
//  the host's phone, so a pause that did not stop it would move the game on
//  under a table still reading the answer; guests only learn of it from the
//  room; and the next question must never start paused.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Game together: pause between questions (#224.4)")
@MainActor
struct RoomPauseTests {
    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let clock = TestClock<Duration>()
    private let analytics = MockAnalyticsClient()
    private let names = PlayerNameStore(defaults: UserDefaults(suiteName: "room-pause-\(UUID().uuidString)")!)
    private let store = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-pause-rules-\(UUID().uuidString)")!)

    private func makeModel() -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        store.save(MultiplayerSettings(revealMode: .question))
        return RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "device",
            accountName: "Michal", names: names, settingsStore: store, analytics: analytics,
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
    }

    private func hostAtReveal() async -> RoomViewModel {
        let model = makeModel()
        await model.beginHosting()
        await model.startGame()
        await model.readTask?.value
        await model.submitOption(key: "b")
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        return model
    }

    @Test("Staying stops the host's countdown for good; resuming starts it over; Next clears the pause")
    func stayStopsAutoAdvance() async {
        let model = await hostAtReveal()
        defer { model.stopAll() }
        let delay = QuizSettings.default.autoAdvanceDelay
        #expect(model.autoAdvanceLeft == delay)

        await model.togglePause()
        #expect(rooms.pauseCalls == [true])
        #expect(model.isPaused)
        #expect(model.autoAdvanceLeft == nil)

        await clock.advance(by: .seconds(delay * 3))
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(model.round?.number == 1, "a paused reveal must not move on by itself")

        await model.togglePause()
        #expect(rooms.pauseCalls == [true, false])
        #expect(!model.isPaused)
        #expect(model.autoAdvanceLeft == delay, "resuming gives the full reading time again")
        await clock.advance(by: .seconds(delay))
        await model.advanceTask?.value
        #expect(model.round?.number == 2)
    }

    @Test("Next while paused still moves on, and the next question starts unpaused")
    func nextEndsThePause() async {
        let model = await hostAtReveal()
        defer { model.stopAll() }
        await model.togglePause()
        await model.next()
        await model.readTask?.value
        #expect(model.round?.number == 2)
        #expect(!model.isPaused)
    }

    @Test("Each pause or resume is counted once with the question it happened on")
    func pauseIsMeasured() async {
        let model = await hostAtReveal()
        defer { model.stopAll() }
        await model.togglePause()
        await model.togglePause()
        #expect(analytics.events == [.roomPauseChanged(paused: true, question: 1), .roomPauseChanged(paused: false, question: 1)])
    }

    @Test("A refused pause keeps the countdown running and counts nothing")
    func refusedPauseKeepsCountdown() async {
        let model = await hostAtReveal()
        defer { model.stopAll() }
        // The room refuses a pause on a question that is not revealed any more.
        rooms.hostMovesOn()
        await model.togglePause()
        for _ in 0 ..< 5 {
            await Task.yield()
        }
        #expect(analytics.events.isEmpty)
        #expect(model.autoAdvanceLeft != nil)
    }

    @Test("A guest sees the host's pause from the room and never gets a control")
    func guestSeesPause() async {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        defer { model.stopAll() }
        rooms.hostStarts()
        await model.refresh()
        await model.submitOption(key: "a")
        #expect(model.screen == .reveal)
        #expect(!model.isPaused)

        rooms.hostPauses(true)
        await model.refresh()
        #expect(model.isPaused)

        await model.togglePause()
        #expect(rooms.pauseCalls.isEmpty, "only the host can pause")

        rooms.hostPauses(false)
        await model.refresh()
        #expect(!model.isPaused)
    }
}
