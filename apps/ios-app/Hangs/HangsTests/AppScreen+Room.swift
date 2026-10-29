//
//  AppScreen+Room.swift
//  HangsTests
//
//  #212.3 — a game together: the host's lobby (QR code, players), a guest's
//  lobby, an open A–D question on a guest's phone, the host's reveal and the
//  host's final ranking with the leave-app line. Each is the scripted mock
//  room driven to that step, then stopped, so nothing moves while it renders.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI

extension AppScreen {
    func makeRoom() async -> AnyView {
        let rooms = MockRoomService()
        let model = Self.roomModel(rooms, guestName: self == .roomLobbyGuest || self == .roomQuestion ? "Peťo" : nil)
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

    private static func roomModel(_ rooms: MockRoomService, guestName: String?) -> RoomViewModel {
        let network = MockNetworkService()
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        let names = PlayerNameStore(defaults: UserDefaults(suiteName: "room-snapshot-\(UUID().uuidString)")!)
        if let guestName { names.save(guestName) }
        return RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "snapshot",
            accountName: guestName == nil ? "Michal" : nil, names: names, calls: StillCalls(),
            clock: AnyClock(TestClock()), languageCode: "en", isOffCellular: { true }
        )
    }
}

/// Never on a call: the snapshot has no CallKit.
@MainActor
private final class StillCalls: CallStatusProviding {
    var isOnCall: Bool { false }
}
