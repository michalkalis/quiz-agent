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

    /// "No sound" (founder 2026-11-22): the silent mode switch under Quick quiz.
    var silentModeSwitch: XCUIElement {
        app.switches["home.silentMode"].firstMatch
    }

    /// TestFlight build 90 (Home A1): the gear at the top opens Settings.
    var settingsButton: XCUIElement {
        app.buttons["home.settings"]
    }

    /// While a start is in flight, Start turns into this Cancel control.
    var cancelStartButton: XCUIElement {
        app.buttons["home.cancelStart"]
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

    /// #205: the daily challenge card's play pill (not played yet).
    var dailyPlayButton: XCUIElement {
        app.buttons["home.daily.play"]
    }

    /// #205: the played daily challenge card (opens its round end).
    var dailyOpenButton: XCUIElement {
        app.buttons["home.daily.open"]
    }

    /// #236: "Štart s deťmi", Home's start in the family mode.
    var startFamilyButton: XCUIElement {
        app.buttons["home.startFamily"]
    }

    /// #236: the "With kids" half of the mode switch. A segment of a
    /// segmented picker may not carry its tag's identifier, so the second
    /// segment of `home.mode` stands in for it.
    var familyModeSegment: XCUIElement {
        let tagged = app.buttons["home.mode.family"]
        return tagged.exists ? tagged : app.segmentedControls["home.mode"].buttons.element(boundBy: 1)
    }

    /// #236: an age band in the first-flip sheet ("kids_4_6").
    func familyBand(_ band: String) -> XCUIElement {
        app.buttons["family.band.\(band)"]
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
