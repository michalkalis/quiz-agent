//
//  RSProfileTests.swift
//  HangsUITests
//
//  RS-30 — the tab bar and the Profile tab (#213.4). RS-31 — the recap story
//  (#213.5). Cards and recaps come from the mock graph
//  (`UITestSupport.makeMockPlayerStats`), no backend.
//

import XCTest

final nonisolated class RSProfileTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: RS-30 — Profile: plan, All stats, Settings under the gear; a quiz hides the tab bar

    // Regression guarded: Settings left Home for the Profile tab, so the gear
    // there is the only way in; #216.3 moved the plan here and the stat cards
    // behind "All stats" (open and locked ones, without the retired cards);
    // and a quiz must keep the full screen, with no tab bar to wander off to.
    @MainActor
    func testRS30ProfileTabAndQuizHidesTabBar() {
        let app = RSFlow.launch()
        let profile = ProfilePage(app: app)

        XCTAssertFalse(app.buttons["home.moreSettings"].exists, "RS-30: Home still carries the old settings gear")
        XCTAssertFalse(profile.planLabel.exists, "RS-30: the plan is still on Home")
        profile.open()
        XCTAssertTrue(profile.planLabel.waitForExistence(timeout: 5), "RS-30: the plan is missing on the Profile")
        XCTAssertFalse(app.buttons["profile.myPacks"].exists, "RS-30: My packs is still on the Profile")

        profile.allStatsButton.tap()
        XCTAssertTrue(profile.card("totals").waitForExistence(timeout: 5), "RS-30: totals card missing in All stats")
        XCTAssertFalse(profile.card("hard_questions").exists, "RS-30: a retired card is still shown")
        app.navigationBars.buttons.element(boundBy: 0).tap() // a11y-id: system back button

        XCTAssertTrue(profile.settingsButton.waitForExistence(timeout: 5), "RS-30: did not return to the Profile")
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

    // MARK: RS-31 — the recap card shows on the Profile with Share

    // Regression guarded: the recap is the reason to come back each month;
    // #216.3 made it one card on the Profile, and Share must be there (the
    // picture renders).
    @MainActor
    func testRS31RecapCardHasShare() {
        let app = RSFlow.launch()
        let profile = ProfilePage(app: app)

        profile.open()
        XCTAssertTrue(profile.recapCard.waitForExistence(timeout: 5), "RS-31: recap card missing")
        XCTAssertTrue(profile.recapShare.waitForExistence(timeout: 5), "RS-31: Share missing on the recap card")
        RSFlow.assertAlive(app, "RS-31")
    }
}
