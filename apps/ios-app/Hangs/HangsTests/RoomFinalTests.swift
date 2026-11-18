//
//  RoomFinalTests.swift
//  HangsTests
//
//  #224.5 — the end of a game together lists every question with what each
//  player answered. Why it matters: the table argues about who knew what, so
//  the final screen must hold every player's own answer (not only the viewer's)
//  for every question, in both reveal modes.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Game together: final screen rows (#224.5)")
@MainActor
struct RoomFinalTests {
    private func finishedGame(_ mode: RoomState.RevealMode) async -> RoomViewModel {
        let rooms = MockRoomService()
        let network = MockNetworkService()
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        let store = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-final-\(UUID().uuidString)")!)
        store.save(MultiplayerSettings(revealMode: mode))
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "d",
            accountName: "Michal", names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-final-n-\(UUID().uuidString)")!),
            settingsStore: store, clock: AnyClock(TestClock()), languageCode: "sk", isOffCellular: { true }
        )
        await model.beginHosting()
        await model.startGame()
        await model.readTask?.value
        await model.submitOption(key: "b")
        await model.next()
        await model.readTask?.value
        model.typedAnswer = "Canberra"
        await model.submitTypedAnswer()
        await model.next()
        model.stopAll()
        return model
    }

    @Test("Every question carries every player's own answer, in either reveal mode")
    func everyPlayerEveryQuestion() async {
        for mode in RoomState.RevealMode.allCases {
            let model = await finishedGame(mode)
            #expect(model.screen == .finished)
            let summaries = model.roundSummaries
            #expect(summaries.count == 2)
            // Question 1 is A–D: the option's text, not the key, for both players.
            #expect(summaries[0].rows.map(\.answer) == ["Saturn", "Saturn"])
            #expect(summaries[0].rows.allSatisfy { $0.isCorrect })
            // Question 2 is typed: the host was right, the other player was not.
            #expect(summaries[1].rows.map(\.answer) == ["Canberra", "Sydney"])
            #expect(summaries[1].rows.map(\.isCorrect) == [true, false])
        }
    }
}
