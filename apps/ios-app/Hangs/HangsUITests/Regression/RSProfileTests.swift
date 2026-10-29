//
//  RSProfileTests.swift
//  HangsUITests
//
//  RS-30 — the tab bar and the Profile tab (#213.4). The stat cards come
//  from the mock graph (`UITestSupport.makeMockPlayerStats`), no backend.
//

import XCTest

final nonisolated class RSProfileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-30 — Profile shows the cards, Settings sits under its gear, a quiz hides the tab bar

    // Regression guarded: Settings left Home for the Profile tab, so the gear
    // there is the only way in; the cards must render (open and locked); and a
    // quiz must keep the full screen, with no tab bar to wander off to.
    @MainActor
    func testRS30ProfileTabAndQuizHidesTabBar() {
        let app = RSFlow.launch()
        let profile = ProfilePage(app: app)

        XCTAssertFalse(app.buttons["home.moreSettings"].exists, "RS-30: Home still carries the old settings gear")
        profile.open()
        XCTAssertTrue(profile.card("totals").waitForExistence(timeout: 5), "RS-30: totals card missing")
        XCTAssertTrue(profile.card("hard_questions").exists, "RS-30: locked hard-questions card missing")
        XCTAssertTrue(profile.myPacksButton.exists, "RS-30: profile.myPacks row missing")

        profile.settingsButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.voiceCommands"].waitForExistence(timeout: 5),
            "RS-30: Settings did not open from the Profile gear"
        )

        profile.playTab.tap()
        let question = RSFlow.startQuiz(app)
        question.waitForState("askingQuestion", timeout: 10)
        let tab = profile.profileTab
        XCTAssertFalse(tab.exists && tab.isHittable, "RS-30: the tab bar is still on screen during a quiz")
        RSFlow.assertAlive(app, "RS-30")
    }
}
