//
//  RoomCategoriesTests.swift
//  HangsTests
//
//  #249.1 (founder 2026-11-26): the host picks the categories of a game
//  together right in "What we play". Why it matters: the choice must reach the
//  room's session (or the picker is decoration), and it is the room's own: the
//  solo categories on Home never change through a game together (#212), or a
//  friends' game would silently rewrite the host's everyday quiz.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Game together: categories in What we play (#249.1)")
@MainActor
struct RoomCategoriesTests {
    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let clock = TestClock<Duration>()
    private let defaults = UserDefaults(suiteName: "room-categories-\(UUID().uuidString)")!

    private var soloSettings: QuizSettings {
        var solo = QuizSettings.default
        solo.categories = ["history"]
        return solo
    }

    private func makeModel(extras: [ExtraCategory] = []) -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        rooms.conditions.networkClock = AnyClock(clock)
        return RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: soloSettings, deviceId: "device",
            accountName: "Michal",
            names: PlayerNameStore(defaults: UserDefaults(suiteName: "room-categories-names-\(UUID().uuidString)")!),
            settingsStore: MultiplayerSettingsStore(defaults: defaults), clock: AnyClock(clock), languageCode: "sk",
            isOffCellular: { true }, packsEnabled: { true }, extraCategories: { extras },
            pendingLeaves: PendingRoomLeaveStore(defaults: UserDefaults(suiteName: "room-categories-leave-\(UUID().uuidString)")!)
        )
    }

    @Test("a new room plays all categories, not the host's solo selection")
    func defaultIsAllCategories() async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }

        #expect(network.capturedCategories == [], "the room's own default is All Categories")
        #expect(model.solo.categories == ["history"])
    }

    @Test("the picked categories reach the new session and are kept apart from solo")
    func pickedCategoriesReachSessionNotSolo() async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }

        await model.play(.categories, categories: ["sports", "science-nature"])

        #expect(network.capturedCategories == ["sports", "science-nature"])
        #expect(model.settings.categories == ["sports", "science-nature"])
        #expect(model.solo.categories == ["history"], "solo settings never change through a game together (#212)")
        #expect(MultiplayerSettingsStore(defaults: defaults).load().categories == ["sports", "science-nature"], "kept for the next game")
    }

    @Test("a failed change puts the categories back")
    func failedChangeKeepsCategories() async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }
        let hold = rooms.conditions.hold(.createRoom)
        let change = Task { await model.play(.categories, categories: ["sports"]) }
        await pumpUntil { hold.heldCount == 1 }

        rooms.conditions.setNetworkCondition(.serverError(statusCode: 500), for: [.createRoom])
        hold.release()
        await advanceUntil(clock, limit: .seconds(60)) { model.errorMessage != nil }
        await change.value

        #expect(model.settings.categories == [], "the host must see what the room still plays")
        #expect(MultiplayerSettingsStore(defaults: defaults).load().categories == [])
    }

    @Test("an extra category the server no longer lists is not sent")
    func unlistedExtraIsDropped() async {
        defaults.set(try? JSONEncoder().encode(MultiplayerSettingsStore.Choices(categories: ["extra-gone", "extra-live", "history"])), forKey: "multiplayer_settings")
        let model = makeModel(extras: [ExtraCategory(key: "extra-live", name: "Live", until: nil)])
        await model.beginHosting()
        defer { model.stopAll() }

        #expect(network.capturedCategories == ["extra-live", "history"], "a rotated-out extra would be refused by the server")
    }
}
