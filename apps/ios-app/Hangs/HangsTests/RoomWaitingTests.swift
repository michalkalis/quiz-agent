//
//  RoomWaitingTests.swift
//  HangsTests
//
//  #240.9 (founder 2026-11-18): no silent waiting in a game together. Why it
//  matters: guests used to look at a still screen while the host's phone read
//  the question (up to 45 s) and at "Question closed" while the answers were
//  checked, with no sign anything was happening. Now the reading shows solo's bar,
//  the waiting player sees who answered (never what), grading says so, and a
//  question the judge could not check says it counts for nobody instead of a
//  silent zero. The reveal taps once, like the solo result.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing

@Suite("Game together: no silent waiting (#240.9)")
@MainActor
struct RoomWaitingTests {
    private let rooms = MockRoomService()
    private let clock = TestClock<Duration>()

    private func guest() async -> RoomViewModel {
        let network = MockNetworkService()
        rooms.conditions.networkClock = AnyClock(clock)
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "device",
            accountName: "Peťo",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "waiting-names-\(UUID().uuidString)")!),
            settingsStore: MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "waiting-rules-\(UUID().uuidString)")!),
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
        await model.join(.token(MockRoomService.token))
        return model
    }

    // #249.5: the reading is solo's bar state ("Reading the question"), then
    // the answer time drains in the same bar; it goes once this player answered.
    @Test("While the host's phone reads, the bar says so, then counts the answer time down")
    func readingThenCountdown() async {
        let model = await guest()
        defer { model.stopAll() }
        rooms.beginGame()
        await model.refresh()
        #expect(model.round?.phase == .reading)
        #expect(model.listenPhase == .readingQuestion, "a still screen while the host reads is the silent wait")

        rooms.hostOpens()
        await model.refresh()
        #expect(model.listenPhase == .thinking(remaining: 20, total: 20))
        await clock.advance(by: .seconds(5))
        #expect(model.listenPhase == .thinking(remaining: 15, total: 20))

        await model.submitOption(key: "b")
        #expect(model.listenPhase == nil, "the time is the others' once this player answered")
    }

    @Test("A player who answered sees who else did, then that the answers are being checked, then the reveal")
    func answeredAndGrading() async throws {
        rooms.othersAnswerLater = true
        rooms.holdGrading = true
        let model = await guest()
        defer { model.stopAll() }
        rooms.hostStarts()
        await model.refresh()
        let you = try #require(model.players.last?.displayName)
        let host = try #require(model.players.first?.displayName)

        await model.submitOption(key: "b")
        #expect(model.answeredNames == [you])
        #expect(!model.isGrading)

        rooms.othersAnswer()
        await model.refresh()
        #expect(model.isGrading, "everyone answered and nothing said the answers are being checked")
        #expect(model.answeredNames == [host, you])

        rooms.finishGrading()
        await model.refresh()
        #expect(!model.isGrading)
        #expect(model.screen == .reveal)
        #expect(model.revealOutcome == .correct)
    }

    @Test("A question the judge could not check is marked cancelled and taps neutrally")
    func cancelledQuestion() async {
        rooms.cancelledQuestions = [1]
        let model = await guest()
        defer { model.stopAll() }
        rooms.hostStarts()
        await model.refresh()
        await model.submitOption(key: "b")

        #expect(model.round?.isCancelled == true)
        #expect(model.revealOutcome == .cancelled, "a right answer that scored nothing would read as a bug")
        #expect(RoomRevealView.haptic(for: model.revealOutcome) == .selection)
    }

    @Test("The reveal taps like the solo result: success when right, a soft tap when not")
    func revealHaptics() async {
        let model = await guest()
        defer { model.stopAll() }
        rooms.hostStarts()
        await model.refresh()
        await model.submitOption(key: "a")

        #expect(model.revealOutcome == .miss)
        #expect(RoomRevealView.haptic(for: .miss) == ResultView.missHaptic)
        #expect(RoomRevealView.haptic(for: .correct) == .success)
    }
}
