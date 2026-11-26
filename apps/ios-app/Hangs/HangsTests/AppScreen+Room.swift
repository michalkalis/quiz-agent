//
//  AppScreen+Room.swift
//  HangsTests
//
//  #212.3 — a game together (#224.4: host question, typed reveal, guest on a pause): the host's lobby (QR code, players), a guest's
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
        let settings = [.roomReveal, .roomRevealTyped, .roomRevealPaused, .roomRevealCancelled, .roomFinal, .roomFinalExpanded, .roomFinalGuest].contains(self) ? MultiplayerSettings(revealMode: .question) : MultiplayerSettings()
        let model = Self.roomModel(rooms, guestName: [.roomLobbyGuest, .roomQuestion, .roomRevealPaused, .roomQuestionReading, .roomQuestionGrading, .roomFinalGuest, .roomQuestionPaused].contains(self) ? "Peťo" : nil, settings: settings)
        switch self {
        case .roomLobbyHost:
            await model.beginHosting()
        case .roomLobbyHostFull:
            // #224: four players and the start button on one screen, no scrolling.
            rooms.extraGuests = ["Peťo", "Zuzka"]
            await model.beginHosting()
        case .roomLobbyGuest:
            await model.join(.token(MockRoomService.token))
        case .roomQuestion:
            await model.join(.token(MockRoomService.token))
            rooms.hostStarts()
            await model.refresh()
        case .roomQuestionHost:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
        case .roomQuestionPaused:
            await model.join(.token(MockRoomService.token))
            rooms.hostStarts()
            await model.refresh()
            rooms.hostPauses(true)
            await model.refresh()
        case .roomQuestionPausedHost:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            await model.togglePause()
        case .roomRevealPaused:
            await model.join(.token(MockRoomService.token))
            rooms.hostStarts()
            await model.refresh()
            await model.submitOption(key: "a")
            rooms.hostPauses(true)
            await model.refresh()
        case .roomRevealTyped:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            await model.submitOption(key: "b")
            await model.next()
            await model.readTask?.value
            model.typedAnswer = "Canberra"
            await model.submitTypedAnswer()
        case .roomQuestionReading:
            // #240.9: the host's phone reads the question; the bar shows it.
            await model.join(.token(MockRoomService.token))
            rooms.beginGame()
            await model.refresh()
        case .roomQuestionGrading:
            // #240.9: everyone answered, the answers are being checked.
            rooms.othersAnswerLater = true
            rooms.holdGrading = true
            await model.join(.token(MockRoomService.token))
            rooms.hostStarts()
            await model.refresh()
            await model.submitOption(key: "a")
            rooms.othersAnswer()
            await model.refresh()
        case .roomRevealCancelled:
            rooms.cancelledQuestions = [1]
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            await model.submitOption(key: "b")
        case .roomFinalGuest:
            await model.join(.token(MockRoomService.token))
            rooms.hostStarts()
            await model.refresh()
            await model.submitOption(key: "b")
            rooms.hostMovesOn()
            await model.refresh()
            model.typedAnswer = "Canberra"
            await model.submitTypedAnswer()
            rooms.hostMovesOn()
            await model.refresh()
        case .roomReveal:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            await model.submitOption(key: "b")
        case .roomRulesLobby:
            // #224: opened from the lobby's rules row, the reveal is editable.
            await model.beginHosting()
            model.stopAll()
            return AnyView(RoomRulesSheet(viewModel: model).background(Theme.Hangs.Colors.bg))
        case .roomRules:
            await model.beginHosting()
            await model.startGame()
            await model.readTask?.value
            model.stopAll()
            return AnyView(RoomRulesSheet(viewModel: model).background(Theme.Hangs.Colors.bg))
        case .roomFinal, .roomFinalExpanded, .roomRankingShareImage:
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
        if self == .roomRankingShareImage {
            // #240.9: the picture "Share" sends (like the recap's, on the device canvas).
            return AnyView(RoomRankingShareImage(ranks: model.rankRows, awards: model.awardRows, total: model.state?.maxQuestions ?? 0))
        }
        if self == .roomFinalExpanded {
            // Both questions open: the host's answer, the others' and the marks.
            return AnyView(RoomFinalView(viewModel: model, expanded: [1, 2], onShowPlans: {}, onClose: {}).background(Theme.Hangs.Colors.bg))
        }
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
