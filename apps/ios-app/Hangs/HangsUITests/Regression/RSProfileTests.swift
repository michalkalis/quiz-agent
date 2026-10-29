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

    // MARK: RS-31 — the recap banner plays the story to the shareable last slide

    // Regression guarded: the recap is the reason to come back each month; the
    // banner must open the story, tapping must reach the last slide, Share
    // must be there (the image renders), and Close must return to the Profile.
    @MainActor
    func testRS31RecapStoryReachesShare() {
        let app = RSFlow.launch()
        let profile = ProfilePage(app: app)

        profile.open()
        XCTAssertTrue(profile.recapBanner.waitForExistence(timeout: 5), "RS-31: recap banner missing")
        profile.recapBanner.tap()
        XCTAssertTrue(profile.story.waitForExistence(timeout: 5), "RS-31: the story did not open")

        for _ in 0 ..< 10 where !profile.storyShare.exists {
            profile.storyNext.tap()
        }
        XCTAssertTrue(profile.storyShare.waitForExistence(timeout: 5), "RS-31: Share missing on the last slide")

        profile.storyClose.tap()
        XCTAssertTrue(profile.settingsButton.waitForExistence(timeout: 5), "RS-31: Close did not return to the Profile")
        XCTAssertFalse(profile.story.exists, "RS-31: the story is still on screen after Close")
        RSFlow.assertAlive(app, "RS-31")
    }
}
