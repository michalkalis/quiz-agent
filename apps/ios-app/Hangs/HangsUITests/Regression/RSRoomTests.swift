//
//  RSRoomTests.swift
//  HangsUITests
//
//  RS-28..RS-29 — a game together (#212.3) on the scripted mock room: two
//  questions (A–D, then typed), one other player. The server switch is
//  seeded by `--app-config-multiplayer`; a guest's host is driven over the
//  test listener.
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

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-28: Together button missing on Home")
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
        room.startButton.tap()

        // Question 1 (A–D) opens after the read-aloud.
        XCTAssertTrue(room.option("b").waitForExistence(timeout: 10), "RS-28: options missing on question 1")
        room.option("b").tap()
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-28: reveal missing after question 1")
        room.nextButton.tap()

        // Question 2 (typed).
        XCTAssertTrue(room.answerField.waitForExistence(timeout: 10), "RS-28: answer field missing on question 2")
        room.typeAnswer("Canberra")
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-28: reveal missing after question 2")
        room.nextButton.tap()

        XCTAssertTrue(room.winner.waitForExistence(timeout: 10), "RS-28: final ranking missing")
        XCTAssertEqual(room.winner.label, "Michal", "RS-28: wrong winner")
        XCTAssertTrue(room.awayNote.exists, "RS-28: the host's leave-app line missing")
        room.doneButton.tap()
        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 5), "RS-28: not back on Home")
        RSFlow.assertAlive(app, "RS-28")
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

        XCTAssertTrue(room.togetherButton.waitForExistence(timeout: 10), "RS-29: Home not ready")
        try await client.openRoomLink(token: "mock-token")
        XCTAssertTrue(room.renameCard.waitForExistence(timeout: 10), "RS-29: guest lobby missing after the link")

        try await client.roomHostStarts()
        XCTAssertTrue(room.option("b").waitForExistence(timeout: 10), "RS-29: question 1 missing")
        room.option("b").tap()
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-29: reveal missing after question 1")
        XCTAssertTrue(room.waitingForHost.exists, "RS-29: guest is not waiting for the host")
        XCTAssertFalse(room.nextButton.exists, "RS-29: a guest must not move the game on")

        try await client.roomHostMovesOn()
        XCTAssertTrue(room.answerField.waitForExistence(timeout: 10), "RS-29: question 2 missing")
        room.typeAnswer("Sydney")
        XCTAssertTrue(room.revealAnswer.waitForExistence(timeout: 10), "RS-29: reveal missing after question 2")

        try await client.roomHostMovesOn()
        XCTAssertTrue(room.winner.waitForExistence(timeout: 10), "RS-29: final ranking missing")
        XCTAssertFalse(room.awayNote.exists, "RS-29: a guest sees the host-only leave-app line")
        RSFlow.assertAlive(app, "RS-29")
    }
}
