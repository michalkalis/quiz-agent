//
//  AppScreen+Room.swift
//  HangsTests
//
//  #212.3 — a game together: the host's lobby (QR code, players), a guest's
//  lobby, an open A–D question on a guest's phone, the host's reveal and the
//  host's final ranking with the leave-app line, and the host's in-game rules
//  sheet (#213.8). The host lobby shows the rules card with the defaults, the
//  guest lobby the host's rules read-only. Each is the scripted mock
//  room driven to that step, then stopped, so nothing moves while it renders.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makeRoom() async -> AnyView {
        let rooms = MockRoomService()
        // The reveal and final screens show the per-question reveal; the
        // lobbies and the rules sheet show the defaults.
        let settings = self == .roomReveal || self == .roomFinal ? MultiplayerSettings(revealMode: .question) : MultiplayerSettings()
        let model = Self.roomModel(rooms, guestName: self == .roomLobbyGuest || self == .roomQuestion ? "Peťo" : nil, settings: settings)
        switch self {
        case .roomLobbyHost:
            await model.beginHosting()
        case .roomLobbyGuest:
            await model.join(.token(MockRoomService.token))
        case .roomQuestion:
            await model.join(.token(MockRoomService.token))
            rooms.hostStarts()
            await model.refresh()
        case .roomReveal:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            await model.submitOption(key: "b")
        case .roomRules:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            model.stopAll()
            return AnyView(RoomRulesSheet(viewModel: model).background(Theme.Hangs.Colors.bg))
        case .roomFinal:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            await model.submitOption(key: "b")
            await model.next()
            await model.readTask?.value
            model.typedAnswer = "Canberra"
            await model.submitTypedAnswer()
            await model.next()
        default: preconditionFailure("\(self) is not a game-together screen")
        }
        model.stopAll()
        return AnyView(RoomFlowView(viewModel: model, onShowPlans: {}, onClose: {}))
    }

    private static func roomModel(_ rooms: MockRoomService, guestName: String?, settings: MultiplayerSettings) -> RoomViewModel {
        let network = MockNetworkService()
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        let names = PlayerNameStore(defaults: UserDefaults(suiteName: "room-snapshot-\(UUID().uuidString)")!)
        if let guestName { names.save(guestName) }
        let store = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-snapshot-rules-\(UUID().uuidString)")!)
        store.save(settings)
        return RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "snapshot",
            accountName: guestName == nil ? "Michal" : nil, names: names, settingsStore: store, calls: StillCalls(),
            clock: AnyClock(TestClock()), languageCode: "en", isOffCellular: { true }
        )
    }
}

/// Never on a call: the snapshot has no CallKit.
@MainActor
private final class StillCalls: CallStatusProviding {
    var isOnCall: Bool { false }
}
