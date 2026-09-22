//
//  A11yIdentifierTests.swift
//  HangsUITests
//
//  #180 track E: locators go by accessibilityIdentifier, never by visible
//  text (the UI ships in sk/cs/en). The lint (scripts/lint-a11y-ids.py) proves
//  every control declares one; this proves the one place where declaring is
//  not obviously enough — SwiftUI Menu items, rendered by UIKit's menu
//  machinery — still surfaces the identifier to XCUITest. If Apple ever stops
//  forwarding identifiers for menu items, this fails loud and the Home/Settings
//  pickers must be driven another way.
//

import XCTest

final nonisolated class A11yIdentifierTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testHomeMenuItemsAreLocatableByIdentifier() {
        let app = RSFlow.launch()
        HomePage(app: app).assertVisible()

        let menu = app.descendants(matching: .any)["home-language-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "home-language-menu missing on Home")
        menu.tap()

        // English is always in the quiz-language catalogue, so its item is
        // the stable probe regardless of what the availability mock serves.
        let item = app.buttons["home.language.en"]
        XCTAssertTrue(
            item.waitForExistence(timeout: 5),
            "Menu item home.language.en not exposed — menu items lost their identifiers"
        )
        item.tap()
        HomePage(app: app).assertVisible()
    }
}
