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

    var togetherButton: XCUIElement { app.buttons["home.together"] }
    var hostButton: XCUIElement { app.buttons["room.host"] }
    var nameField: XCUIElement { app.textFields["room.name.field"] }
    var nameSave: XCUIElement { app.buttons["room.name.save"] }
    var qrCode: XCUIElement { app.images["room.qr"] }
    var startButton: XCUIElement { app.buttons["room.start"] }
    var renameCard: XCUIElement { app.buttons["room.lobby.rename"] }
    var questionText: XCUIElement { app.descendants(matching: .any)["question.text"] }
    var answerField: XCUIElement { app.textFields["room.answer.field"] }
    var sendButton: XCUIElement { app.buttons["room.answer.send"] }
    var revealAnswer: XCUIElement { app.descendants(matching: .any)["room.reveal.answer"] }
    var waitingForHost: XCUIElement { app.descendants(matching: .any)["room.waitingForHost"] }
    var nextButton: XCUIElement { app.buttons["room.next"] }
    var winner: XCUIElement { app.descendants(matching: .any)["room.final.winner"] }
    var awayNote: XCUIElement { app.descendants(matching: .any)["room.final.away"] }
    var doneButton: XCUIElement { app.buttons["room.done"] }
    var rulesReveal: XCUIElement { app.buttons["room.rules.reveal"] }
    var rulesTime: XCUIElement { app.buttons["room.rules.time"] }
    var rulesReadsAloud: XCUIElement { app.descendants(matching: .any)["room.rules.readsAloud"] }
    var guestRules: XCUIElement { app.descendants(matching: .any)["room.rules.guest"] }
    var rulesOpen: XCUIElement { app.buttons["room.rules.open"] }

    func revealOption(_ mode: String) -> XCUIElement {
        app.buttons["room.rules.reveal.\(mode)"]
    }

    func timeOption(_ seconds: Int) -> XCUIElement {
        app.buttons["room.rules.time.\(seconds)"]
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
