//
//  RSRoomTests.swift
//  HangsUITests
//
//  RS-28..RS-29, RS-32 — a game together (#212.3, rules #213.8) on the scripted mock room: two
//  questions (A–D, then typed), one other player. The server switch is
//  seeded by `--app-config-multiplayer`; a guest's host is driven over the
//  test listener. RS-41..RS-42 (#235.5): the host loses the network mid-game,
//  a guest comes back from the background.
//

import XCTest

final nonisolated class RSRoomTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-28 — The host plays a whole game

    // Regression guarded: the host's phone drives the game for everyone. A
    // step that stalls (no read-then-open, no next) leaves every phone on the
    // same question; the final ranking and the host-only leave-app line must
    // show at the end.
    @MainActor
    func testRS28HostPlaysAWholeGame() {
        let app = RSFlow.launch(["--app-config-multiplayer"])
        let room = RoomPage(app: app)

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-28: Together tab missing")
        room.togetherButton.tap()
        XCTAssertTrue(room.hostButton.waitForExistence(timeout: 5), "RS-28: Host a game missing")
        room.hostButton.tap()

        // No account in UI tests: the host is asked for a name once.
        if room.nameField.waitForExistence(timeout: 3) {
            room.nameField.tap()
            room.nameField.typeText("Michal")
            room.nameSave.tap()
        }
        XCTAssertTrue(room.qrCode.waitForExistence(timeout: 10), "RS-28: lobby QR code missing")
        XCTAssertTrue(room.player("p_other").exists, "RS-28: joined player missing from the lobby")
        // #240.9: a game together reveals after each question by default;
        // this run still picks it in the lobby's rules, so the sheet is driven.
        room.lobbyRules.tap()
        XCTAssertTrue(room.rulesReveal.waitForExistence(timeout: 5), "RS-28: rules sheet missing")
        room.rulesReveal.tap()
        XCTAssertTrue(room.revealOption("question").waitForExistence(timeout: 5), "RS-28: reveal choices missing")
        room.revealOption("question").tap()
        room.rulesDone.tap()
        XCTAssertTrue(room.startButton.waitForExistence(timeout: 5), "RS-28: start missing after the rules sheet")
        room.startButton.tap()

        // Question 1 (A–D) opens after the read-aloud.
        XCTAssertTrue(room.option("b").waitForExistence(timeout: 10), "RS-28: options missing on question 1")
        room.option("b").tap()
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-28: reveal missing after question 1")
        room.nextButton.tap()

        // Question 2 (typed).
        XCTAssertTrue(room.typeButton.waitForExistence(timeout: 10), "RS-28: Type missing on question 2")
        room.typeAnswer("Canberra")
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-28: reveal missing after question 2")
        room.nextButton.tap()

        XCTAssertTrue(room.winner.waitForExistence(timeout: 10), "RS-28: final ranking missing")
        XCTAssertEqual(room.winner.label, "Michal", "RS-28: wrong winner")
        XCTAssertTrue(room.awayNote.exists, "RS-28: the host's leave-app line missing")
        // #240.9: the end gives more than the winner a moment and a way to go on.
        XCTAssertTrue(room.award("fastest").exists, "RS-28: awards missing")
        XCTAssertTrue(room.playAgainButton.exists, "RS-28: Play again missing for the host")
        XCTAssertTrue(room.shareButton.exists, "RS-28: share missing on the final ranking")
        room.doneButton.tap()
        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 5), "RS-28: the tab bar did not come back")
        RSFlow.assertAlive(app, "RS-28")
    }

    // MARK: RS-32 — The host sets the rules in the lobby; a guest only reads them

    // Regression guarded: the rules hold for every phone (#213.8). A first game
    // starts from the group defaults (#240.9: after each question, 15 s), not the host's
    // solo choices; a change shows at once; a guest sees the host's rules but
    // has no control to change them.
    @MainActor
    func testRS32HostSetsTheRulesGuestReadsThem() async throws {
        let app = RSFlow.launch(["--app-config-multiplayer"])
        let room = RoomPage(app: app)

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-32: Together tab missing")
        room.togetherButton.tap()
        XCTAssertTrue(room.hostButton.waitForExistence(timeout: 5), "RS-32: Host a game missing")
        room.hostButton.tap()
        if room.nameField.waitForExistence(timeout: 3) {
            room.nameField.tap()
            room.nameField.typeText("Michal")
            room.nameSave.tap()
        }
        // #224: the lobby shows the rules as one row; the sheet changes them.
        XCTAssertTrue(room.lobbyRules.waitForExistence(timeout: 10), "RS-32: rules row missing in the host lobby")
        XCTAssertTrue(room.spoken(room.lobbyRules).contains("After each question"), "RS-32: reveal default is not after each question")
        XCTAssertTrue(room.spoken(room.lobbyRules).contains("15 s"), "RS-32: answer time default is not 15 s")
        room.lobbyRules.tap()
        XCTAssertTrue(room.rulesReveal.waitForExistence(timeout: 5), "RS-32: reveal is not editable in the lobby's sheet")
        XCTAssertTrue(room.rulesReadsAloud.exists, "RS-32: read-aloud switch missing")

        XCTAssertTrue(room.timeOption(45).waitForExistence(timeout: 5), "RS-32: answer time choices missing")
        room.timeOption(45).tap()
        room.rulesDone.tap()
        let updated = NSPredicate(format: "label CONTAINS %@", "45 s")
        let wait = XCTNSPredicateExpectation(predicate: updated, object: room.lobbyRules)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 5), .completed, "RS-32: answer time did not change to 45 s")
        RSFlow.assertAlive(app, "RS-32 host")

        // A guest in a fresh launch: the host's rules, read-only.
        app.terminate()
        let guestApp = RSFlow.launch(["--app-config-multiplayer"])
        let guest = RoomPage(app: guestApp)
        XCTAssertTrue(guest.togetherButton.waitForExistence(timeout: 10), "RS-32: Together tab not ready for the guest")
        try await UITestClient().openRoomLink(token: "mock-token")
        XCTAssertTrue(guest.renameCard.waitForExistence(timeout: 10), "RS-32: guest lobby missing after the link")
        XCTAssertTrue(guest.guestRules.waitForExistence(timeout: 5), "RS-32: the host's rules missing for the guest")
        XCTAssertFalse(guest.rulesReveal.exists, "RS-32: a guest must not change the reveal")
        XCTAssertFalse(guest.rulesTime.exists, "RS-32: a guest must not change the answer time")
        XCTAssertFalse(guest.rulesReadsAloud.exists, "RS-32: a guest must not change reading aloud")
        RSFlow.assertAlive(guestApp, "RS-32 guest")
    }

    // MARK: RS-29 — A guest joins by link and follows the host

    // Regression guarded: a join link must open the game on Home; the guest
    // answers, sees each reveal, waits for the host (never gets a Next) and
    // never sees the host-only leave-app line.
    @MainActor
    func testRS29GuestJoinsByLinkAndFollowsTheHost() async throws {
        let app = RSFlow.launch(["--app-config-multiplayer"])
        let room = RoomPage(app: app)
        let client = UITestClient()

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-29: Together tab not ready")
        try await client.openRoomLink(token: "mock-token")
        XCTAssertTrue(room.renameCard.waitForExistence(timeout: 10), "RS-29: guest lobby missing after the link")

        try await client.roomHostStarts()
        XCTAssertTrue(room.option("b").waitForExistence(timeout: 10), "RS-29: question 1 missing")
        room.option("b").tap()
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-29: reveal missing after question 1")
        XCTAssertTrue(room.waitingForHost.exists, "RS-29: guest is not waiting for the host")
        XCTAssertFalse(room.nextButton.exists, "RS-29: a guest must not move the game on")

        try await client.roomHostMovesOn()
        XCTAssertTrue(room.typeButton.waitForExistence(timeout: 10), "RS-29: question 2 missing")
        room.typeAnswer("Sydney")
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-29: reveal missing after question 2")

        try await client.roomHostMovesOn()
        XCTAssertTrue(room.winner.waitForExistence(timeout: 10), "RS-29: final ranking missing")
        XCTAssertFalse(room.awayNote.exists, "RS-29: a guest sees the host-only leave-app line")
        RSFlow.assertAlive(app, "RS-29")
    }

    // MARK: RS-41 — The host loses the network mid-game

    // Regression guarded (#235.5): the host's phone drives the game, so a dead
    // connection must show (the slow-connection line), the game must go on by
    // itself once the network is back, and leaving must work at any time.
    @MainActor
    func testRS41HostLosesTheNetworkMidGame() async throws {
        let app = RSFlow.launch(["--app-config-multiplayer"])
        let room = RoomPage(app: app)
        let client = UITestClient()
        hostAGame(room, "RS-41")
        XCTAssertTrue(room.option("b").waitForExistence(timeout: 10), "RS-41: options missing on question 1")

        try await client.setNetwork("offline")
        XCTAssertTrue(room.connectionBanner.waitForExistence(timeout: 10), "RS-41: no slow-connection line while every poll fails")
        XCTAssertTrue(room.closeButton.isHittable, "RS-41: the host cannot leave while the network is gone")

        try await client.setNetwork("clear")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: room.connectionBanner)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "RS-41: the slow-connection line stayed after the network came back")
        room.option("b").tap()
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-41: the game did not go on after the network came back")

        room.closeButton.tap()
        // a11y-id: system alert — confirmationDialog buttons carry no identifiers; English is pinned by RSFlow.baseLaunchArguments
        let endGame = app.buttons["End game"]
        XCTAssertTrue(endGame.waitForExistence(timeout: 3), "RS-41: no End game confirmation")
        endGame.tap()
        XCTAssertTrue(room.hostButton.waitForExistence(timeout: 5), "RS-41: not back on the Together tab after ending the game")
        RSFlow.assertAlive(app, "RS-41")
    }

    // MARK: RS-42 — A guest back from the background sees the current question

    // Regression guarded (#235.5): a guest who switched apps while the host
    // moved on must come back to the question the room is on, not the stale
    // reveal they left.
    @MainActor
    func testRS42GuestBackFromTheBackgroundIsOnTheCurrentQuestion() async throws {
        let app = RSFlow.launch(["--app-config-multiplayer"])
        let room = RoomPage(app: app)
        let client = UITestClient()

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-42: Together tab not ready")
        try await client.openRoomLink(token: "mock-token")
        XCTAssertTrue(room.renameCard.waitForExistence(timeout: 10), "RS-42: guest lobby missing after the link")
        try await client.roomHostStarts()
        XCTAssertTrue(room.option("b").waitForExistence(timeout: 10), "RS-42: question 1 missing")
        room.option("b").tap()
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-42: reveal missing after question 1")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended, "RS-42: the app did not go to the background")
        try await client.roomHostMovesOn()
        app.activate()

        XCTAssertTrue(room.typeButton.waitForExistence(timeout: 10), "RS-42: the guest is not on question 2 after coming back")
        XCTAssertFalse(room.revealAnswer.exists, "RS-42: the stale reveal of question 1 is still on screen")
        XCTAssertFalse(room.waitingForHost.exists, "RS-42: the guest still waits for a host who moved on")
        RSFlow.assertAlive(app, "RS-42")
    }

    /// Together tab → Host → name if asked → per-question reveal → Start.
    @MainActor
    private func hostAGame(_ room: RoomPage, _ scenario: String) {
        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "\(scenario): Together tab missing")
        room.togetherButton.tap()
        XCTAssertTrue(room.hostButton.waitForExistence(timeout: 5), "\(scenario): Host a game missing")
        room.hostButton.tap()
        if room.nameField.waitForExistence(timeout: 3) {
            room.nameField.tap()
            room.nameField.typeText("Michal")
            room.nameSave.tap()
        }
        XCTAssertTrue(room.lobbyRules.waitForExistence(timeout: 10), "\(scenario): lobby missing")
        room.lobbyRules.tap()
        XCTAssertTrue(room.rulesReveal.waitForExistence(timeout: 5), "\(scenario): rules sheet missing")
        room.rulesReveal.tap()
        XCTAssertTrue(room.revealOption("question").waitForExistence(timeout: 5), "\(scenario): reveal choices missing")
        room.revealOption("question").tap()
        room.rulesDone.tap()
        XCTAssertTrue(room.startButton.waitForExistence(timeout: 5), "\(scenario): start missing")
        room.startButton.tap()
    }
}
