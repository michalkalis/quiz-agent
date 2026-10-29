//
//  RoomViewModelTests.swift
//  HangsTests
//
//  #212.3 — a game together on one phone's side. Why it matters: every phone
//  shows the same game only if it follows the server's room (its version and
//  its remaining time, never the phone's own clock); the host's phone drives
//  the game (reads, opens, moves on) so a missed step stalls everyone; and the
//  leave-app note (#212.4) must never blame a player who was on a call or had
//  already answered.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@Suite("Game together: room view model (#212.3)")
@MainActor
struct RoomViewModelTests {
    private final class FakeCalls: CallStatusProviding {
        var isOnCall = false
    }

    private let rooms = MockRoomService()
    private let network = MockNetworkService()
    private let audio = MockAudioService()
    private let calls = FakeCalls()
    private let clock = TestClock<Duration>()
    private let names = PlayerNameStore(defaults: UserDefaults(suiteName: "room-tests-\(UUID().uuidString)")!)
    private let settingsStore = MultiplayerSettingsStore(defaults: UserDefaults(suiteName: "room-rules-\(UUID().uuidString)")!)

    /// Most of these follow a per-question reveal; the round mode has its own test.
    private static let perQuestion = MultiplayerSettings(revealMode: .question)

    private func makeModel(
        accountName: String? = "Michal Kalis",
        solo: QuizSettings = .default,
        settings: MultiplayerSettings = Self.perQuestion
    ) -> RoomViewModel {
        network.mockSession = QuizResponse.previewStartQuiz.session
        network.mockResponse = .previewStartQuiz
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        settingsStore.save(settings)
        return RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: solo, deviceId: "device",
            accountName: accountName, names: names, settingsStore: settingsStore, calls: calls,
            clock: AnyClock(clock), languageCode: "sk", isOffCellular: { true }
        )
    }

    /// A host whose first question is open for answers.
    private func hostAtFirstQuestion(settings: MultiplayerSettings = Self.perQuestion) async -> RoomViewModel {
        let model = makeModel(settings: settings)
        await model.beginHosting()
        await model.startGame()
        await model.readTask?.value
        return model
    }

    // MARK: - Host

    @Test("The host's name comes from the account (first name only), and the lobby shows who joined")
    func hostLobby() async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }

        #expect(model.screen == .lobby)
        #expect(model.isHost)
        #expect(model.me?.displayName == "Michal")
        #expect(model.players.map(\.displayName) == ["Michal", "Jana"])
        #expect(model.created?.inviteURL.absoluteString == "https://trubbo.app/join?t=mock-token")
    }

    @Test("Without an account name the host is asked once, and that name is kept for the next game")
    func hostWithoutName() async {
        let model = makeModel(accountName: nil)
        await model.beginHosting()
        #expect(model.isAskingHostName)
        #expect(model.created == nil)

        await model.confirmHostName("  Zuzka  ")
        defer { model.stopAll() }
        #expect(!model.isAskingHostName)
        #expect(model.me?.displayName == "Zuzka")
        #expect(names.chosenName == "Zuzka")
    }

    @Test("The host's phone reads the question aloud first and only then opens the answer time")
    func hostReadsThenOpens() async {
        let model = await hostAtFirstQuestion()
        defer { model.stopAll() }

        #expect(audio.playOpusCallCount == 1)
        #expect(rooms.openCalls == 1)
        #expect(model.round?.phase == .answering)
        #expect(model.screen == .question)
        #expect(model.canAnswer)
    }

    @Test("A host who turned reading aloud off opens the answer time at once")
    func silentHostOpensAtOnce() async {
        let model = await hostAtFirstQuestion(settings: MultiplayerSettings(revealMode: .question, readsAloud: false))
        defer { model.stopAll() }

        #expect(audio.playOpusCallCount == 0)
        #expect(rooms.openCalls == 1)
    }

    @Test("A whole game: answers, reveals, the host's phone moves on by itself, and the final ranking")
    func wholeGame() async {
        let model = await hostAtFirstQuestion()
        defer { model.stopAll() }

        // Question 1 (A–D): the option key goes to the server, the reveal shows its text.
        await model.submitOption(key: "b")
        #expect(rooms.answers == ["b"])
        #expect(model.screen == .reveal)
        let round = try? #require(model.round)
        if let round {
            #expect(model.revealRows(for: round).map(\.answer) == ["Saturn", "Saturn"])
            #expect(model.correctCount(in: round) == 2)
        }

        // After the reveal the host's phone counts down and moves on alone.
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(model.autoAdvanceLeft == QuizSettings.default.autoAdvanceDelay)
        await clock.advance(by: .seconds(QuizSettings.default.autoAdvanceDelay))
        await model.advanceTask?.value
        await model.readTask?.value
        #expect(model.round?.number == 2)
        #expect(model.screen == .question)

        // Question 2 (typed).
        model.typedAnswer = "  Canberra "
        await model.submitTypedAnswer()
        #expect(rooms.answers == ["b", "Canberra"])

        await model.next()
        #expect(model.screen == .finished)
        #expect(model.rankRows.first?.name == "Michal")
        #expect(model.rankRows.first?.correctCount == 2)
        #expect(model.awayRows.map(\.name) == ["Jana"], "the host sees who left the app")
    }

    @Test("In round mode results wait for the end, where option keys show as their text")
    func roundMode() async {
        let model = await hostAtFirstQuestion(settings: MultiplayerSettings(revealMode: .round))
        defer { model.stopAll() }

        await model.submitOption(key: "b")
        #expect(model.screen == .roundWait)
        #expect(model.yourAnswerText == "Saturn")

        await model.next()
        await model.readTask?.value
        model.typedAnswer = "Sydney"
        await model.submitTypedAnswer()
        await model.next()

        #expect(model.screen == .finished)
        let summaries = model.roundSummaries
        #expect(summaries.map(\.yourAnswer) == ["Saturn", "Sydney"])
        #expect(summaries.map(\.youWereRight) == [true, false])
    }

    @Test("Removing a player takes them off the host's list")
    func removePlayer() async {
        let model = makeModel()
        await model.beginHosting()
        defer { model.stopAll() }
        let jana = try? #require(model.players.first { !$0.isHost })
        guard let jana else { return }

        await model.remove(jana)
        #expect(rooms.removed == [MockRoomService.otherId])
        #expect(model.players.map(\.displayName) == ["Michal"])
    }

    // MARK: - Time

    @Test("The countdown follows the server's remaining time on the injected clock")
    func countdownFollowsServer() async {
        let model = await hostAtFirstQuestion()
        defer { model.stopAll() }

        #expect(model.secondsLeft() == 20)
        #expect(model.answerWindowSeconds == 20)
        await clock.advance(by: .seconds(7))
        #expect(model.secondsLeft() == 13)
        await clock.advance(by: .seconds(30))
        #expect(model.secondsLeft() == 0)
        #expect(!model.canAnswer, "no answer after the time is up")
    }

    @Test("An older or unchanged room reply never replaces what the phone already shows")
    func versionOrdering() async {
        let model = await hostAtFirstQuestion()
        defer { model.stopAll() }
        let shown = try? #require(model.state)
        guard let shown else { return }

        model.apply(RoomState(
            roomId: shown.roomId, version: shown.version - 1, changed: true, status: .lobby, you: nil, isHost: nil,
            questionNumber: nil, maxQuestions: nil, players: [], revealMode: nil, thinkingSeconds: nil,
            readsAloud: nil, question: nil, round: nil, finishedReason: nil, ranking: nil, rounds: nil, away: nil
        ))
        #expect(model.state == shown)

        await model.refresh()
        #expect(model.state == shown, "an unchanged poll keeps the full state")
    }

    // MARK: - Leaving the app (#212.4)

    @Test("Leaving the app during an open question is reported once per question")
    func awayOncePerQuestion() async {
        let model = await hostAtFirstQuestion()
        defer { model.stopAll() }

        model.appMovedToBackground()
        model.appMovedToBackground()
        await Task.yield()
        await Task.yield()
        #expect(rooms.awayReports == ["mq1"])
    }

    @Test("No leave-app note during a phone call, after answering, or in the lobby")
    func awayNotBlamed() async {
        let lobby = makeModel()
        await lobby.beginHosting()
        lobby.appMovedToBackground()
        lobby.stopAll()

        let model = await hostAtFirstQuestion()
        defer { model.stopAll() }
        calls.isOnCall = true
        model.appMovedToBackground()
        calls.isOnCall = false
        await model.submitOption(key: "b")
        model.appMovedToBackground()
        await Task.yield()
        await Task.yield()
        #expect(rooms.awayReports.isEmpty)
    }

    // MARK: - Guest

    @Test("A guest joins with an automatic name and can rename in the lobby, kept for the next game")
    func guestRename() async {
        let model = makeModel(accountName: nil)
        await model.join(.token(MockRoomService.token))
        defer { model.stopAll() }

        #expect(model.screen == .lobby)
        #expect(!model.isHost)
        let automatic = model.playerName
        #expect(rooms.joinNames == [automatic])

        await model.rename(to: "Peťo")
        #expect(rooms.joinNames == [automatic, "Peťo"])
        #expect(model.me?.displayName == "Peťo")
        #expect(names.chosenName == "Peťo")
    }

    @Test("A guest follows the host: question, answer, reveal, next")
    func guestFollowsHost() async {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        defer { model.stopAll() }

        rooms.hostStarts()
        await model.refresh()
        #expect(model.screen == .question)
        await model.submitOption(key: "a")
        #expect(model.screen == .reveal)
        #expect(model.me?.score == 0)

        rooms.hostMovesOn()
        await model.refresh()
        #expect(model.round?.number == 2)
        #expect(model.screen == .question)
        #expect(rooms.openCalls == 0, "only the host opens a question")
    }

    @Test("A game that is full or over says so, and the guest stays on the start screen")
    func joinRefused() async {
        rooms.joinError = NetworkError.serverError(statusCode: 409, message: "full")
        let model = makeModel()
        await model.join(.token("t"))
        defer { model.stopAll() }

        #expect(model.screen == .start)
        #expect(model.errorMessage == RoomViewModel.joinMessage(for: NetworkError.serverError(statusCode: 409, message: "")))
    }

    // MARK: - Connection

    @Test("A slow connection shows after three failed polls and clears on the next reply")
    func connectionTrouble() async {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        model.stopAll()

        rooms.stateError = URLError(.timedOut)
        await model.refresh()
        await model.refresh()
        #expect(!model.connectionTrouble)
        await model.refresh()
        #expect(model.connectionTrouble)

        rooms.stateError = nil
        await model.refresh()
        #expect(!model.connectionTrouble)
    }

    @Test("A room that is gone (removed, or the host ended it) ends the game on this phone")
    func roomGone() async {
        let model = makeModel()
        await model.join(.token(MockRoomService.token))
        model.stopAll()

        rooms.stateError = NetworkError.serverError(statusCode: 404, message: "gone")
        await model.refresh()
        #expect(model.screen == .ended)
    }

    @Test("The Wi-Fi list is not searched on mobile data")
    func nearbyOffWiFi() async {
        rooms.nearby = [NearbyRoom(roomId: "r", hostName: "Michal", hostColor: "#ff6b2c", playerCount: 2)]
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: audio, solo: .default, deviceId: "device",
            names: names, calls: calls, clock: AnyClock(clock), languageCode: "sk", isOffCellular: { false }
        )
        await model.searchNearby()
        #expect(model.nearbyStatus == .offWiFi)
        #expect(model.nearby.isEmpty)
    }
}

@Suite("Game together: invite, name and settings (#212.3)")
struct RoomSupportTests {
    @Test("Only a trubbo.app join link with a token opens a game")
    func inviteLinks() {
        #expect(RoomInvite.token(from: URL(string: "https://trubbo.app/join?t=abc")!) == "abc")
        #expect(RoomInvite.token(from: URL(string: "https://trubbo.app/join/?t=abc")!) == "abc")
        #expect(RoomInvite.token(from: URL(string: "https://trubbo.app/join?t=")!) == nil)
        #expect(RoomInvite.token(from: URL(string: "https://evil.example/join?t=abc")!) == nil)
        #expect(RoomInvite.token(from: URL(string: "http://trubbo.app/join?t=abc")!) == nil)
        #expect(RoomInvite.token(from: URL(string: "https://trubbo.app/other?t=abc")!) == nil)
    }

    @Test("A scanned QR code and a shared link reach the same game but are counted apart")
    func qrAndLinkAreToldApart() throws {
        // #212.5: the verdict on game together asks whether guests scan or need
        // the link, so the QR code carries its own mark on the same token.
        let created = RoomCreated(roomId: "r", joinToken: "abc", sessionId: "s")
        #expect(created.qrURL.absoluteString == "https://trubbo.app/join?t=abc#qr")
        #expect(RoomInvite.invite(from: created.qrURL) == .qr("abc"))
        #expect(RoomInvite.invite(from: created.inviteURL) == .token("abc"))
        #expect(RoomInvite.invite(from: try #require(URL(string: "https://trubbo.app/x#qr"))) == nil)
    }

    @Test("Names are trimmed and capped so they fit the lists on every phone")
    func nameCleaning() {
        #expect(PlayerNameStore.cleaned("  Jana ") == "Jana")
        #expect(PlayerNameStore.cleaned("   ") == nil)
        #expect(PlayerNameStore.cleaned(String(repeating: "a", count: 40))?.count == PlayerNameStore.maxLength)
        #expect(PlayerNameStore.automaticName(languageCode: "sk", pick: { _ in 0 }) == "Rýchly gepard")
        #expect(PlayerNameStore.automaticName(languageCode: "en", pick: { _ in 0 }) == "Swift Cheetah")
    }

    @Test("A game together never has voice or picture questions")
    func neverVoiceOrPictures() {
        // Guests have no voice and the host taps like everyone else; pictures
        // are not in the first version. A switch here would split the room.
        #expect(!MultiplayerSettings.voiceCommandsEnabled)
        #expect(!MultiplayerSettings.hostAnswersByVoice)
        #expect(!MultiplayerSettings.includeImageQuestions)
    }
}
