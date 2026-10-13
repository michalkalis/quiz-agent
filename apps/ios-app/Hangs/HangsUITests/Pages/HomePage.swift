//
//  HomePage.swift
//  HangsUITests
//
//  Page Object for the Home screen.
//

import XCTest

struct HomePage {
    let app: XCUIApplication

    var startQuizButton: XCUIElement {
        app.buttons["home.startQuiz"]
    }

    /// "Create your own pack" — opens the same order sheet as Settings.
    var createPackButton: XCUIElement {
        app.buttons["home.createPack"]
    }

    /// #200: the play control on the first pack card under "my packs".
    var packPlayButton: XCUIElement {
        app.buttons["home.myPacks.play"].firstMatch
    }

    /// #200: "Played N / M" on a pack card this phone has started.
    var packProgress: XCUIElement {
        app.staticTexts["home.myPacks.progress"].firstMatch
    }

    /// The "Create your own pack" row closes the packs card, below the deck
    /// and the pills (Home order since 2026-10-13), so on a phone it starts
    /// off screen: scroll Home until it is there.
    func revealCreatePack(maxSwipes: Int = 3) -> XCUIElement {
        let row = createPackButton
        var swipes = 0
        while !row.waitForExistence(timeout: 2), swipes < maxSwipes {
            app.scrollViews.firstMatch.swipeUp()
            swipes += 1
        }
        return row
    }

    /// Tap the Start Quiz button and return immediately (caller waits for destination).
    func tapStartQuiz() {
        startQuizButton.tap()
    }

    /// Assert the home screen is visible by checking the Start Quiz button exists.
    func assertVisible(timeout: TimeInterval = 5) {
        XCTAssertTrue(
            startQuizButton.waitForExistence(timeout: timeout),
            "HomePage: home.startQuiz button not found"
        )
    }
}
