//
//  RoomPage.swift
//  HangsUITests
//
//  Page Object for a game together (#212): start, lobby, question, reveal
//  and the final ranking; the host's rules (#213.8).
//

import XCTest

struct RoomPage {
    let app: XCUIApplication

    /// #216.2: the Together tab (it replaced the Together button on Home).
    var togetherButton: XCUIElement { app.tabBars.buttons["tab.together"] }
    var hostButton: XCUIElement { app.buttons["room.host"] }
    var nameField: XCUIElement { app.textFields["room.name.field"] }
    var nameSave: XCUIElement { app.buttons["room.name.save"] }
    var qrCode: XCUIElement { app.images["room.qr"] }
    var startButton: XCUIElement { app.buttons["room.start"] }
    var renameCard: XCUIElement { app.buttons["room.lobby.rename"] }
    var questionText: XCUIElement { app.descendants(matching: .any)["question.text"] }
    var answerField: XCUIElement { app.textFields["room.answer.field"] }
    var sendButton: XCUIElement { app.buttons["room.answer.send"] }
    /// The reveal's "Correct: n/m" line: on every reveal, A–D and typed (#224.4).
    var revealAnswer: XCUIElement { app.descendants(matching: .any)["room.reveal.count"] }
    var waitingForHost: XCUIElement { app.descendants(matching: .any)["room.waitingForHost"] }
    var nextButton: XCUIElement { app.buttons["room.next"] }
    var winner: XCUIElement { app.descendants(matching: .any)["room.final.winner"] }
    var awayNote: XCUIElement { app.descendants(matching: .any)["room.final.away"] }
    var doneButton: XCUIElement { app.buttons["room.done"] }
    /// #224: the lobby's one-line rules row; it opens the rules sheet.
    var lobbyRules: XCUIElement { app.buttons["room.lobby.rules"] }
    var rulesReveal: XCUIElement { app.buttons["room.rules.sheet.reveal"] }
    var rulesTime: XCUIElement { app.segmentedControls["room.rules.sheet.time"] }
    var rulesReadsAloud: XCUIElement { app.descendants(matching: .any)["room.rules.sheet.readsAloud"] }
    var rulesDone: XCUIElement { app.buttons["room.rules.done"] }
    var guestRules: XCUIElement { app.descendants(matching: .any)["room.rules.guest"] }
    var rulesOpen: XCUIElement { app.buttons["room.rules.open"] }

    func revealOption(_ mode: String) -> XCUIElement {
        app.buttons["room.rules.sheet.reveal.\(mode)"]
    }

    /// A segment of the sheet's answer time picker (segments carry no identifier).
    func timeOption(_ seconds: Int) -> XCUIElement {
        rulesTime.buttons["\(seconds) s"] // a11y-id: segment label, UI pinned to English
    }

    /// What a rules row shows: its label and value as VoiceOver reads them.
    func spoken(_ element: XCUIElement) -> String {
        "\(element.label) \(element.value as? String ?? "")"
    }

    func player(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)["room.player.\(id)"]
    }

    func nearbyGame(_ roomId: String) -> XCUIElement {
        app.buttons["room.nearby.\(roomId)"]
    }

    func option(_ key: String) -> XCUIElement {
        app.buttons["mcq.option.\(key)"]
    }

    func typeAnswer(_ text: String) {
        answerField.tap()
        answerField.typeText(text)
        sendButton.tap()
    }
}
