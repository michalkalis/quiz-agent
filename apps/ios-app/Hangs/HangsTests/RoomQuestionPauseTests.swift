//
//  RoomQuestionPauseTests.swift
//  HangsTests
//
//  #249.4 (founder 2026-11-26): the host pauses a game together while a
//  question is open, from the solo-style top bar. Why it matters: the answer
//  time is the server's and shared, so the pause has to stop every phone's
//  countdown, not just the host's; a clip being read must stop with it and
//  come back after; only the host may pause; and a slow or failed pause must
//  never leave the host without a way back or the game stuck mid-read.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("Game together: pause while a question is open (#249.4)")
@MainActor
struct RoomQuestionPauseTests {
    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let audio = MockAudioService()
    private let clock = TestClock<Duration>()
    private let analytics = MockAnalyticsClient()
    private let names = PlayerNameStore(defaults: UserDefaults(suiteName: "room-qpause-\(UUID().uuidString)")!)
    private let store = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-qpause-rules-\(UUID().uuidString)")!)

    private func makeModel(accountName: String? = "Michal") -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        rooms.conditions.networkClock = AnyClock(clock)
        store.save(MultiplayerSettings(revealMode: .question))
        return RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: .default, deviceId: "device",
            accountName: accountName, names: names, settingsStore: store, analytics: analytics,
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
    }

    /// The host's phone is reading the first question aloud (the clip never ends by itself).
    private func hostReading() async -> RoomViewModel {
        audio.holdsPlaybackUntilStopped = true
        let model = makeModel()
        await model.beginHosting()
        await model.startGame()
        await pumpUntil({ audio.isPlaying }, "the host's phone never started reading")
        return model
    }

    /// The first question is open for answers on the host's phone.
    private func hostAnswering() async -> RoomViewModel {
        let model = makeModel()
        await model.beginHosting()
        await model.startGame()
        await model.readTask?.value
        return model
    }

    private func guestAnswering() async -> RoomViewModel {
        let model = makeModel(accountName: nil)
        await model.join(.token(MockRoomService.token))
        rooms.hostStarts()
        await model.refresh()
        return model
    }

    // MARK: - Host

    @Test("A pause while answering stops the time left on the host's phone; answers still go in")
    func pauseWhileAnswering() async {
        let model = await hostAnswering()
        defer { model.stopAll() }
        #expect(model.round?.phase == .answering)
        let left = model.secondsLeft()

        await model.togglePause()
        #expect(rooms.pauseCalls == [true])
        #expect(model.isPaused)
        await clock.advance(by: .seconds(60))
        #expect(model.secondsLeft() == left, "a paused question counted down on this phone")
        #expect(model.canAnswer, "answers count while paused, so the options stay open")

        await model.submitOption(key: "b")
        #expect(model.screen == .question, "the question must not reveal while paused")
        await model.togglePause()
        #expect(!model.isPaused)
        #expect(model.screen == .reveal, "every answer was in: the resume reveals")
        #expect(analytics.events == [
            .roomPauseChanged(paused: true, question: 1, phase: "answering"),
            .roomPauseChanged(paused: false, question: 1, phase: "answering"),
        ])
    }

    @Test("A pause while the host's phone reads stops the clip and holds the clock; the resume reads it again")
    func pauseWhileReading() async {
        let model = await hostReading()
        defer { model.stopAll() }

        await model.togglePause()
        #expect(audio.stopPlaybackCallCount == 1, "the question kept playing through the pause")
        await model.readTask?.value
        #expect(rooms.openCalls == 0, "a stopped read must not start the answer time")
        #expect(model.isPaused && model.round?.phase == .reading)

        await model.togglePause()
        await pumpUntil({ audio.playOpusCallCount == 2 }, "the resume did not read the question again")
        audio.finishHeldClip()
        await model.readTask?.value
        #expect(rooms.openCalls == 1)
        #expect(model.round?.phase == .answering)
    }

    @Test("A slow pause shows it is on its way and takes no second tap")
    func slowPause() async {
        let model = await hostAnswering()
        defer { model.stopAll() }
        let hold = rooms.conditions.hold(.setPaused)
        let first = Task { await model.togglePause() }
        await pumpUntil { hold.heldCount == 1 }

        #expect(model.isChangingPause)
        #expect(!model.canTogglePause, "the pause button took a second tap while one was on its way")
        await model.togglePause()
        #expect(hold.arrivals == 1)
        hold.release()
        await first.value
        #expect(model.isPaused)
        #expect(model.canTogglePause, "a paused game lost its way back")
    }

    @Test("A failed pause says so and the game goes on: a clip it stopped is read again")
    func failedPauseWhileReading() async {
        let model = await hostReading()
        defer { model.stopAll() }
        rooms.conditions.setNetworkCondition(.offline, for: [.setPaused])

        await model.togglePause()
        #expect(model.errorMessage != nil, "a pause that did not happen was silent")
        #expect(!model.isPaused)
        await pumpUntil({ audio.playOpusCallCount == 2 }, "the host's phone stopped reading and never went on")
        audio.finishHeldClip()
        await model.readTask?.value
        #expect(rooms.openCalls == 1, "the answer time never started: the room would wait for the fallback")
        #expect(analytics.events.isEmpty)
    }

    @Test("A failed resume says so and keeps the way back")
    func failedResume() async {
        let model = await hostAnswering()
        defer { model.stopAll() }
        await model.togglePause()
        rooms.conditions.setNetworkCondition(.offline, for: [.setPaused])

        await model.togglePause()
        #expect(model.errorMessage != nil)
        #expect(model.isPaused)
        #expect(model.canTogglePause, "the host is stuck in a paused game")
    }

    // MARK: - Guest

    // The paused line itself ("Paused by the host Michal") is frozen in the
    // roomQuestionPaused text contract (AppScreenSnapshotTests).
    @Test("A guest sees the host's pause on the question, the time stands still, no control")
    func guestSeesPausedQuestion() async {
        let model = await guestAnswering()
        defer { model.stopAll() }
        let left = model.secondsLeft()

        rooms.hostPauses(true)
        await model.refresh()
        #expect(model.isPaused)
        await clock.advance(by: .seconds(60))
        #expect(model.secondsLeft() == left)

        await model.togglePause()
        #expect(rooms.pauseCalls.isEmpty, "only the host can pause")
        #expect(model.host?.displayName == "Michal")
    }

    @Test("A pause stops the clip on a guest's phone too")
    func guestClipStops() async {
        audio.holdsPlaybackUntilStopped = true
        let model = makeModel(accountName: nil)
        await model.join(.token(MockRoomService.token))
        defer { model.stopAll() }
        rooms.hostStarts()
        await model.refresh()
        await pumpUntil({ audio.isPlaying }, "the remote guest's phone never read the question")

        rooms.hostPauses(true)
        await model.refresh()
        await pumpUntil({ audio.stopPlaybackCallCount == 1 }, "the guest's phone kept reading through the pause")
    }

    // MARK: - Top bar (solo layout)

    @Test("Every player has the speaker in the top bar; only the host has pause and the rules menu")
    func topBarControls() async throws {
        let host = await hostAnswering()
        defer { host.stopAll() }
        let hostBar = try RoomGameControls(viewModel: host, openRules: {}).inspect()
        for id in ["question.mute", "question.pause", "room.moreMenu"] {
            #expect(throws: Never.self, "host: \(id)") { try hostBar.find(viewWithAccessibilityIdentifier: id) }
        }

        let guestRooms = MockRoomService()
        let guest = RoomViewModel(
            rooms: guestRooms, network: MockNetworkService(), audio: MockAudioService(), solo: .default, deviceId: "guest",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-qpause-guest-\(UUID().uuidString)")!),
            settingsStore: MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-qpause-guest-rules-\(UUID().uuidString)")!),
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
        await guest.join(.token(MockRoomService.token))
        defer { guest.stopAll() }
        let guestBar = try RoomGameControls(viewModel: guest, openRules: {}).inspect()
        #expect(throws: Never.self) { try guestBar.find(viewWithAccessibilityIdentifier: "question.mute") }
        #expect(throws: (any Error).self, "a guest got a pause button") {
            try guestBar.find(viewWithAccessibilityIdentifier: "question.pause")
        }
        #expect(throws: (any Error).self) { try guestBar.find(viewWithAccessibilityIdentifier: "room.moreMenu") }
    }
}
