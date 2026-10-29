//
//  ProfilePage.swift
//  HangsUITests
//
//  #213.4: the tab bar (Play, Profile) and the Profile tab: the stat cards,
//  the gear to Settings and the row to My packs.
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

    var myPacksButton: XCUIElement {
        app.buttons["profile.myPacks"]
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
