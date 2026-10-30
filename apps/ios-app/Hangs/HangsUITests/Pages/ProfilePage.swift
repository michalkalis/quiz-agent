//
//  ProfilePage.swift
//  HangsUITests
//
//  #213.4: the tab bar (Play, Profile) and the Profile tab: the stat cards,
//  the gear to Settings and the row to My packs. #213.5: the recap banner
//  and its story.
//

import XCTest

struct ProfilePage {
    let app: XCUIApplication

    /// Tab bar buttons take the identifier set on each `Tab`.
    var profileTab: XCUIElement {
        app.tabBars.buttons["tab.profile"]
    }

    var playTab: XCUIElement {
        app.tabBars.buttons["tab.play"]
    }

    var settingsButton: XCUIElement {
        app.buttons["profile.settings"]
    }

    /// #216.3: every stat card sits behind this row.
    var allStatsButton: XCUIElement {
        app.buttons["profile.allStats"]
    }

    /// #216.3: the newest recap, one card with Share.
    var recapCard: XCUIElement {
        app.descendants(matching: .any)["profile.recap"]
    }

    var recapShare: XCUIElement {
        app.descendants(matching: .any)["recap.share"]
    }

    /// #216.3: "your plan" moved here from Home.
    var planLabel: XCUIElement {
        app.descendants(matching: .any)["home.planLabel"]
    }

    func card(_ kind: String) -> XCUIElement {
        app.descendants(matching: .any)["profile.card.\(kind)"]
    }

    /// Switch to the Profile tab and wait for its gear.
    func open(timeout: TimeInterval = 5) {
        XCTAssertTrue(profileTab.waitForExistence(timeout: timeout), "ProfilePage: tab.profile not found")
        profileTab.tap()
        XCTAssertTrue(settingsButton.waitForExistence(timeout: timeout), "ProfilePage: profile.settings not found")
    }

    func openSettings(timeout: TimeInterval = 5) {
        open(timeout: timeout)
        settingsButton.tap()
    }
}
