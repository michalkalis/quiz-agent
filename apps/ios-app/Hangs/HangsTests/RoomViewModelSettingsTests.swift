//
//  RoomViewModelSettingsTests.swift
//  HangsTests
//
//  #213.8 — the host's rules for a game together. Why it matters: the rules
//  hold for every phone, so a change the room never got (or a local value
//  that drifts from the room's after a refusal) means the host plays one game
//  and the guests another; the rules are their own set so a game together
//  must never rewrite the host's solo quiz; and `room_settings_changed` is
//  the only signal of which rules hosts actually touch, from where.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Game together: the host's rules (#213.8)")
@MainActor
struct RoomViewModelSettingsTests {
    private final class FakeCalls: CallStatusProviding {
        var isOnCall = false
    }

    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let audio = MockAudioService()
    private let analytics = MockAnalyticsClient()
    private let clock = TestClock<Duration>()
    private let names = PlayerNameStore(defaults: UserDefaults(suiteName: "rules-names-\(UUID().uuidString)")!)
    private let store = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "rules-\(UUID().uuidString)")!)

    private func makeModel(solo: QuizSettings = .default, accountName: String? = "Michal") -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        return RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: solo, deviceId: "device",
            accountName: accountName, names: names, settingsStore: store, analytics: analytics,
            calls: FakeCalls(), clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
    }

    private func hostInLobby() async -> RoomViewModel {
        let model = makeModel()
        await model.beginHosting()
        return model
    }

    private func hostInGame() async -> RoomViewModel {
        let model = await hostInLobby()
        await model.startGame()
        await model.readTask?.value
        return model
    }

    /// #216.2: the tab replaced a small button nobody noticed; comparing tab
    /// visits with games created and joined is how its pull gets measured.
    @Test("Opening the Together tab is logged once, with nothing about the player")
    func tabOpenedIsLogged() {
        let model = makeModel()
        model.tabOpened()

        #expect(analytics.events == [.togetherOpened])
    }

    @Test("A first game together uses the defaults for most players, not the host's solo choices")
    func defaultsIgnoreSolo() async {
        // Founder 2026-10-29: results at the end, 30 s, read aloud. A host who
        // plays solo muted, with per-question results and 5 s must still get
        // the group defaults, and the room is created with them.
        var solo = QuizSettings.default
        solo.answerRevealMode = .perQuestion
        solo.isMuted = true
        solo.thinkingTime = 5
        let model = makeModel(solo: solo)
        await model.beginHosting()
        defer { model.stopAll() }

        #expect(model.settings == MultiplayerSettings(revealMode: .round, thinkingSeconds: 30, readsAloud: true))
        #expect(rooms.revealMode == .round)
        #expect(rooms.thinkingSeconds == 30)
        #expect(rooms.readsAloud)
        #expect(model.state?.thinkingSeconds == 30, "the lobby carries the rules for the guests' card")
    }

    @Test("A change in the lobby reaches the room, is kept for the next game and is logged once from the lobby")
    func lobbyChange() async {
        let model = await hostInLobby()
        defer { model.stopAll() }

        await model.setThinkingSeconds(45)
        #expect(rooms.settingsCalls == [.init(revealMode: nil, thinkingSeconds: 45, readsAloud: nil)], "only the changed rule is sent")
        #expect(model.settings.thinkingSeconds == 45)
        #expect(model.state?.thinkingSeconds == 45, "the room's reply is applied")
        #expect(store.load().thinkingSeconds == 45, "the next game starts with it")

        await model.setRevealMode(.question)
        #expect(model.settings.revealMode == .question)
        #expect(analytics.events == [
            .roomSettingsChanged(setting: .thinkingSeconds, value: "45", surface: .lobby),
            .roomSettingsChanged(setting: .revealMode, value: "question", surface: .lobby),
        ])
    }

    @Test("Picking the value already set sends nothing and logs nothing")
    func sameValueIsNoChange() async {
        let model = await hostInLobby()
        defer { model.stopAll() }

        await model.setThinkingSeconds(30)
        await model.setReadsAloud(true)
        #expect(rooms.settingsCalls.isEmpty)
        #expect(analytics.events.isEmpty, "a no-op would inflate the change counts")
    }

    @Test("Mid-game the answer time and reading aloud change, logged as in game")
    func inGameChange() async {
        let model = await hostInGame()
        defer { model.stopAll() }

        await model.setThinkingSeconds(15)
        await model.setReadsAloud(false)
        #expect(model.settings.thinkingSeconds == 15)
        #expect(!model.settings.readsAloud)
        #expect(analytics.events == [
            .roomSettingsChanged(setting: .thinkingSeconds, value: "15", surface: .inGame),
            .roomSettingsChanged(setting: .readsAloud, value: "false", surface: .inGame),
        ])
    }

    @Test("Once the game started the reveal is fixed: not offered and not sent")
    func revealFixedInGame() async {
        // Switching mid-game would leave guests waiting for a reveal that
        // never comes (or one they already saw); the server refuses it too.
        let model = await hostInGame()
        defer { model.stopAll() }

        #expect(!model.canChangeRevealMode)
        await model.setRevealMode(.question)
        #expect(model.settings.revealMode == .round)
        #expect(rooms.settingsCalls.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("A refused change goes back on the phone and on the device, says so and is not logged")
    func failureReverts() async {
        let model = await hostInLobby()
        defer { model.stopAll() }
        rooms.settingsError = NetworkError.serverError(statusCode: 500, message: "boom")

        await model.setThinkingSeconds(60)
        #expect(model.settings.thinkingSeconds == 30, "the host must see the rule the room plays with")
        #expect(store.load().thinkingSeconds == 30)
        #expect(model.errorMessage == RoomViewModel.genericMessage)
        #expect(!model.isSavingSettings)
        #expect(analytics.events.isEmpty)
    }

    @Test("A guest cannot change the rules")
    func guestCannotChange() async {
        let model = makeModel(accountName: nil)
        await model.join(.token(MockRoomService.token))
        defer { model.stopAll() }

        #expect(!model.canChangeRevealMode)
        await model.setThinkingSeconds(45)
        await model.setRevealMode(.question)
        #expect(rooms.settingsCalls.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("The stored rules survive a restart; an unreadable or out-of-range value falls back safely")
    func storeRoundTrip() {
        let defaults = UserDefaults(suiteName: "rules-store-\(UUID().uuidString)")!
        let store = MultiplayerSettingsStore(defaults: defaults)
        #expect(store.load() == MultiplayerSettings(), "nothing stored yet: the defaults")

        let picked = MultiplayerSettings(revealMode: .question, thinkingSeconds: 45, readsAloud: false)
        store.save(picked)
        #expect(MultiplayerSettingsStore(defaults: defaults).load() == picked)

        defaults.set(Data("not json".utf8), forKey: "multiplayer_settings")
        #expect(store.load() == MultiplayerSettings())

        defaults.set(Data(#"{"reveal_mode":"round","thinking_seconds":600,"reads_aloud":true}"#.utf8), forKey: "multiplayer_settings")
        #expect(store.load().thinkingSeconds == 60, "the server takes 3 to 60 s only")
    }
}
