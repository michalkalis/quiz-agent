//
//  SharedQuizFlowTests.swift
//  HangsTests
//
//  #232 share a quiz by link, in play. Why each rule matters:
//  - with the server switch off nothing of it may show or call the server
//    (the feature ships dark until the founder tests it);
//  - a friend's link plays the server's fixed set: the app must not make a
//    session of its own (a random set, and free quota burnt) nor exclude
//    anything;
//  - a link that cannot be played lands back on Home with the reason;
//  - the link is made on the tap, once, and the share sheet gets text B
//    with the link;
//  - the host's "What we play" moves the lobby to a pack room only while
//    nobody has joined, and ends the old room.
//

import Clocks
import Foundation
@testable import Hangs
import LinkPresentation
import UIKit
import Testing

@MainActor
private func makeViewModel(
    enabled: Bool,
    configure: (MockNetworkService) -> Void = { _ in }
) -> (QuizViewModel, MockNetworkService) {
    let network = Fixtures.makeFullMockNetwork(configure: configure)
    let vm = QuizViewModel(
        networkService: network,
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService(),
        clock: AnyClock(TestClock()),
        sharedQuizEnabled: { enabled }
    )
    return (vm, network)
}

private let created = SharedQuizCreated(
    token: "Ab3_k9-ZxQ", kind: "round", language: "sk", title: nil, categories: ["history"], questionCount: 10
)

@Suite("Shared quiz flow (#232)")
@MainActor
struct SharedQuizFlowTests {
    // MARK: - Switch off

    @Test("switch off: a finished round offers no link")
    func switchOffHidesSending() {
        let (vm, _) = makeViewModel(enabled: false)
        vm.currentSession = Fixtures.makeQuizSession()
        #expect(vm.shareableRoundSessionId == nil)
    }

    @Test("switch on: a finished solo round offers its session; a friend's round does not make a new link")
    func switchOnShowsSending() {
        let (vm, _) = makeViewModel(enabled: true)
        vm.currentSession = Fixtures.makeQuizSession(id: "s_mine")
        #expect(vm.shareableRoundSessionId == "s_mine")
        vm.activeShare = SharedQuizPlay(token: created.token)
        #expect(vm.shareableRoundSessionId == nil)
    }

    // #236: the server answers 409 `family_not_shareable` to a round with
    // kids, so the round end's "Send to a friend" card would be a button that
    // always fails. Play Again and Home stay the round end's actions.
    @Test("switch on: a finished round with kids offers no link")
    func familyRoundOffersNoLink() {
        let (vm, _) = makeViewModel(enabled: true)
        var session = Fixtures.makeQuizSession(id: "s_family")
        session.ageBand = "kids_4_6"
        vm.currentSession = session
        #expect(vm.shareableRoundSessionId == nil)
    }

    @Test("the switch is off unless the server says otherwise")
    func configDefaultsOff() throws {
        let config = try JSONDecoder().decode(RemoteAppConfig.self, from: Data(#"{"orders_enabled": true}"#.utf8))
        #expect(!config.sharedQuizEnabled)
    }

    @Test("switch off: the host still picks categories, the room plays them")
    func switchOffKeepsCategoryChoice() async {
        // #249.1: the packs switch hides only the packs; a game together always
        // lets the host choose what categories the friends play.
        let rooms = MockRoomService()
        rooms.hostAlone = true
        let network = Fixtures.makeFullMockNetwork()
        let model = RoomViewModel(rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "d", accountName: "Michal", clock: AnyClock(TestClock()))
        await model.beginHosting()
        defer { model.stopAll() }
        #expect(model.canChangeContent)

        await model.play(.categories, categories: ["sports"])

        #expect(network.capturedCategories == ["sports"])
        #expect(network.capturedPackId == nil)
    }

    // MARK: - The friend plays

    @Test("a friend's link plays the server's set: no session of its own, nothing excluded")
    func friendStart() async {
        let (vm, network) = makeViewModel(enabled: true) {
            $0.stubbedShareStart = SharedQuizStart(kind: "round", session: Fixtures.makeQuizSession(id: "s_friend"), alreadyPlayed: false)
        }
        vm.persistenceStore.addQuestionId("seen_before")

        await vm.beginSharedQuiz(token: created.token).value

        #expect(network.startSharedQuizCalls.map(\.token) == [created.token])
        #expect(network.createSessionCallCount == 0, "the server owns the shared set")
        #expect(network.capturedStartQuizExcludedIds == [], "the shared set is fixed; history must not reach it")
        #expect(vm.activeShare == SharedQuizPlay(token: created.token, kind: "round"))
        #expect(vm.shareableRoundSessionId == nil)
        vm.taskBag.cancelAll()
    }

    @Test("an already played link shows its comparison on Home, no error, no second attempt")
    func friendAlreadyPlayed() async {
        let (vm, network) = makeViewModel(enabled: true) {
            $0.startSharedQuizError = NetworkError.sharedQuizUnavailable(.alreadyPlayed)
        }

        await vm.beginSharedQuiz(token: created.token).value

        #expect(vm.quizState == .idle)
        #expect(vm.activeShare == nil)
        #expect(vm.sharedQuizComparison == SharedQuizPlay(token: created.token))
        #expect(vm.sharedQuizNotice == nil)
        #expect(network.capturedStartQuizExcludedIds == nil, "nothing may be played twice")
    }

    @Test("a gone link lands on Home with the reason")
    func goneLink() async {
        let (vm, _) = makeViewModel(enabled: true) {
            $0.startSharedQuizError = NetworkError.sharedQuizUnavailable(.notFound)
        }

        await vm.beginSharedQuiz(token: created.token).value

        #expect(vm.quizState == .idle)
        #expect(vm.sharedQuizComparison == nil)
        #expect(vm.sharedQuizNotice == SharedQuizUnavailable.notFound.message)
    }

    @Test("the sender's own link opens the comparison and never starts the quiz again")
    func ownLinkCompares() async {
        let (vm, network) = makeViewModel(enabled: true) {
            $0.stubbedShareResults = SharedQuizResults(
                kind: "round", language: "sk", title: nil, categories: [], questionCount: 10,
                players: [
                    SharedQuizPlayer(name: "Jana", score: 8, total: 10),
                    SharedQuizPlayer(name: "Michal", score: 7, total: 10, isSender: true, isYou: true),
                ]
            )
        }

        await vm.beginSharedQuiz(token: created.token).value

        #expect(vm.sharedQuizComparison == SharedQuizPlay(token: created.token))
        #expect(network.startSharedQuizCalls.isEmpty, "the sender's own link must not start a new round")
        #expect(vm.quizState == .idle)
    }

    @Test("without a typed name one automatic name is kept, so one person reads the same in every comparison")
    func automaticNameKept() throws {
        let names = PlayerNameStore(defaults: try #require(UserDefaults(suiteName: "shared-name-\(UUID().uuidString)")))
        let first = names.playerName(accountName: nil, languageCode: "sk")
        #expect(names.playerName(accountName: nil, languageCode: "sk") == first)
        #expect(names.chosenName == nil, "an automatic name is not a typed one: a host is still asked")
        names.save("Zuzka")
        #expect(names.playerName(accountName: nil) == "Zuzka", "a typed name wins")
    }

    @Test("founder 2026-11-14: an Apple account shows its first name, and a name typed in the Profile wins over it")
    func accountFirstNameThenTyped() throws {
        let names = PlayerNameStore(defaults: try #require(UserDefaults(suiteName: "account-name-\(UUID().uuidString)")))
        #expect(names.playerName(accountName: "Michal Kalis") == "Michal", "friends see the first name, never the surname")
        names.save("Miško")
        #expect(names.playerName(accountName: "Michal Kalis") == "Miško")
    }

    // MARK: - Sending

    @Test("the link is made on the first tap only, and the sheet gets text B with it")
    func sendCreatesOnce() async {
        let network = MockNetworkService()
        network.stubbedShareCreated = created
        var shared: [[Any]] = []
        let model = SharedQuizShareModel(
            network: network, source: .session("s_mine"), displayName: "Michal", present: { shared.append($0) }
        )
        let message: (SharedQuizCreated) -> String = { SharedQuizMessage.round(questionCount: $0.questionCount, score: "7") }

        await model.send(message: message).value
        await model.send(message: message).value

        #expect(network.createSharedQuizCalls.count == 1, "one link per round, reused for every send")
        #expect(network.createSharedQuizCalls.first?.sessionId == "s_mine")
        #expect(network.createSharedQuizCalls.first?.displayName == "Michal")
        #expect(shared.count == 2)
        // #249.6: text and link are two items, so chat apps show a link preview
        // and never turn one long string into a .txt file.
        let items = shared.first
        #expect(items?.count == 2)
        let text = items?.first as? String
        #expect(text?.contains("https://") == false, "the link is its own item, never inside the text")
        let link = (items?.last as? ShareLinkItem)?.activityViewController(UIActivityViewController(activityItems: [], applicationActivities: nil), itemForActivityType: nil)
        #expect(link as? URL == URL(string: "https://trubbo.app/play?s=\(created.token)"))
        #expect(model.token == created.token)
    }

    @Test("founder 2026-11-14: the share sheet header shows the Trubbo mark, the topic and the link, not the message's first words")
    @MainActor
    func shareHeader() throws {
        let url = try #require(URL(string: "https://trubbo.app/play?s=K7m2Qx"))
        let item = ShareLinkItem(url: url, title: "Space · Trubbo", image: UIImage())
        let metadata = try #require(item.activityViewControllerLinkMetadata(UIActivityViewController(activityItems: [], applicationActivities: nil)))
        #expect(metadata.title == "Space · Trubbo")
        #expect(metadata.url == url)
        #expect(metadata.iconProvider != nil, "without an icon the header shows a blank square")
        #expect(metadata.imageProvider != nil, "the daily's score card is the header picture")
    }

    @Test("a failed link says so and opens no sheet")
    func sendFails() async {
        var presented = false
        let model = SharedQuizShareModel(
            network: MockNetworkService(), source: .pack("p1"), displayName: nil, present: { _ in presented = true }
        )
        await model.send { _ in "" }.value
        #expect(!presented)
        #expect(model.failureMessage != nil)
    }

    @Test("the comparison lists best first, the viewer marked, scores as the round end shows them")
    func rows() {
        let rows = SharedQuizShareModel.rows(from: [
            SharedQuizPlayer(name: "Jana", score: 8, total: 10, marks: [true, nil]),
            SharedQuizPlayer(name: "Michal", score: 7.5, total: 10, isSender: true, isYou: true),
        ])
        #expect(rows.map(\.rank) == [1, 2])
        #expect(rows.map(\.score) == ["8", "7.5"])
        #expect(rows.map(\.isYou) == [false, true])
        #expect(rows.first?.marks == [true, nil])
        #expect(rows.last?.marks == nil, "no marks from the server: the row shows none")
    }

    @Test("marks decode when the server sends them, and their absence never loses the comparison")
    func marksDecode() throws {
        let json = #"""
        {"kind":"round","language":"sk","title":null,"categories":[],"question_count":2,"players":[
          {"name":"A","score":1,"total":2,"is_sender":true,"is_you":false,"marks":[true,null]},
          {"name":"B","score":0,"total":2,"is_you":true},
          {"name":"C","score":0,"total":2,"marks":"garbage"}
        ]}
        """#
        let results = try JSONDecoder().decode(SharedQuizResults.self, from: Data(json.utf8))
        #expect(results.players.map(\.marks) == [[true, nil], nil, nil])
        #expect(results.players[1].isYou)
    }

    @Test("the daily invite text asks for the same questions instead of naming the site, and holds no link")
    func dailyInviteText() {
        let day = DailyChallengeDay(year: 2026, month: 11, day: 14)
        let plain = DailyShareText.make(day: day, language: "en", marks: [true, false], score: 1, total: 5, rank: nil)
        let invite = DailyShareText.make(day: day, language: "en", marks: [true, false], score: 1, total: 5, rank: nil, invite: true)
        #expect(plain.hasSuffix("trubbo.app"))
        #expect(invite.hasSuffix("Play the same 5 questions"))
        #expect(!invite.contains("https://"), "the link is a separate share item (#249.6)")
        #expect(invite.contains("✅❌⬜⬜⬜ 1/5"), "the spoiler-free mark line stays in the message")
    }

    @Test("a daily's link opens on the backend page that carries the score card; other links stay on trubbo.app")
    func dailyLinkHost() throws {
        let daily = SharedQuizCreated(token: created.token, kind: "daily", language: "sk", title: nil, categories: [], questionCount: 5)
        #expect(daily.url.absoluteString == "https://api.trubbo.app/play?s=\(created.token)")
        #expect(created.url.host == "trubbo.app")
        // The app still opens it as a quiz link (universal link on either host).
        #expect(SharedQuizLink.token(from: daily.url) == created.token)
    }

    // WHY (#235): the daily share waits on the server for the link. Slow, the
    // button must show it is working and the sheet must still come; failing,
    // the player gets a clear message and no sheet, never an endless wait.
    @Test("slow link creation: busy while in flight, then the sheet gets text and link")
    func dailySendSlow() async {
        let network = MockNetworkService()
        network.stubbedShareCreated = SharedQuizCreated(token: created.token, kind: "daily", language: "sk", title: nil, categories: [], questionCount: 5)
        let hold = network.hold(.createSharedQuiz)
        var shared: [[Any]] = []
        let model = SharedQuizShareModel(network: network, source: .session("s"), displayName: "Jana", present: { shared.append($0) })

        let task = model.send(message: { _ in "text" }, card: { _ in nil })
        await pumpUntil({ hold.heldCount == 1 }, "the call never reached the mock")
        #expect(model.isCreating, "the share button shows it is working")
        #expect(shared.isEmpty)

        hold.release()
        await task.value
        #expect(!model.isCreating)
        #expect(shared.count == 1)
    }

    @Test("failed link creation (offline): a clear message, no sheet, the button is usable again")
    func dailySendOffline() async {
        let network = MockNetworkService()
        network.setNetworkCondition(.offline, for: [.createSharedQuiz])
        var presented = false
        let model = SharedQuizShareModel(network: network, source: .session("s"), displayName: nil, present: { _ in presented = true })
        await model.send(message: { _ in "text" }).value
        #expect(!presented)
        #expect(model.failureMessage != nil)
        #expect(!model.isCreating, "the player can tap Share again")
    }

    // MARK: - What we play (5A)

    @Test("alone in the lobby the host moves the room to a pack and ends the old one")
    func hostPicksPack() async {
        let rooms = MockRoomService()
        rooms.hostAlone = true
        let network = Fixtures.makeFullMockNetwork()
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "d",
            accountName: "Michal", clock: AnyClock(TestClock()), packsEnabled: { true }
        )
        await model.beginHosting()
        defer { model.stopAll() }
        #expect(model.canChangeContent)

        await model.play(.pack(id: "p1", title: "Bridges"))

        #expect(network.capturedPackId == "p1")
        #expect(network.endSessionCallCount == 1, "the first room is closed, not left open in Nearby")
        #expect(model.content == .pack(id: "p1", title: "Bridges"))
        #expect(model.screen == .lobby)
    }

    // #240.9: a guest in the lobby no longer locks the content (the room
    // moves with them, RoomEndgameTests); a game under way still does.
    @Test("once the game started, the content stays")
    func startedGameLocksContent() async {
        let rooms = MockRoomService()
        let network = Fixtures.makeFullMockNetwork()
        network.onStartQuiz = { [rooms] in rooms.beginGame() }
        let model = RoomViewModel(
            rooms: rooms, network: network, audio: MockAudioService(), solo: .default, deviceId: "d",
            accountName: "Michal", clock: AnyClock(TestClock()), packsEnabled: { true }
        )
        await model.beginHosting()
        defer { model.stopAll() }
        await model.startGame()

        await model.play(.pack(id: "p1", title: "Bridges"))

        #expect(!model.canChangeContent)
        #expect(model.content == .categories)
        #expect(rooms.moves == [nil])
    }
}
