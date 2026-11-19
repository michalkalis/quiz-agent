//
//  SharingAndDailyAuditFixTests.swift
//  HangsTests
//
//  #240 — app quality from idle subscription capacity, 240.1 audit findings
//  7, 8, 17, 18, 23 and 24 (240.9 track F). Each test fails on the code the
//  audit read and says what the player would have met.
//

import Clocks
import Foundation
@testable import Hangs
import Testing
import UIKit

@Suite("Sharing and daily challenge audit fixes (#240)")
@MainActor
struct SharingAndDailyAuditFixTests {
    // MARK: - Finding 7: empty comparison

    // WHY: a pack sent from Home has no sender score, so until a friend
    // finishes it the server lists nobody. The sheet showed a spinner that
    // never ended, and the player never learnt that nobody had played yet.
    @Test("an empty comparison reads as answered, not as still loading")
    func emptyComparisonSaysSo() async {
        let network = MockNetworkService()
        network.stubbedShareResults = SharedQuizResults(
            kind: "pack", language: "sk", title: "Hrady", categories: [], questionCount: 10, players: []
        )
        let share = SharedQuizShareModel(network: network, source: nil, token: "Ab3_k9-ZxQ", displayName: "Jana", present: { _ in })
        #expect(!share.hasLoaded, "before the answer the sheet shows its spinner")

        await share.loadResults().value

        #expect(share.rows.isEmpty)
        #expect(!share.loadFailed)
        #expect(share.hasLoaded, "the sheet cannot tell an empty answer from one still on its way")
    }

    // WHY: a failed load is not an empty answer; the sheet keeps saying the
    // link cannot be read, not "nobody finished it".
    @Test("a failed comparison is not reported as answered")
    func failedComparisonNotLoaded() async {
        let share = SharedQuizShareModel(network: MockNetworkService(), source: nil, token: "Ab3_k9-ZxQ", displayName: "Jana", present: { _ in })
        await share.loadResults().value
        #expect(share.loadFailed)
        #expect(!share.hasLoaded)
    }

    // MARK: - Finding 8: Send to a friend after an early exit

    // WHY: "End quiz" deletes the session on the server, so every tap on
    // "Send to a friend" would fail with "Try again" that can never work.
    @Test("a round ended early offers no link; a round played to the end still does")
    func earlyExitOffersNoLink() async {
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            clock: AnyClock(TestClock()),
            sharedQuizEnabled: { true }
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .askingQuestion
        #expect(vm.shareableRoundSessionId != nil, "precondition: a live round can be sent")

        await vm.endQuizWithResults()

        #expect(vm.quizState == .finished)
        #expect(vm.shareableRoundSessionId == nil, "the round end offers a link the server can never make")

        // The next round is a new session: it can be sent again.
        vm.currentSession = Fixtures.makeQuizSession(id: "s_next")
        #expect(vm.shareableRoundSessionId == "s_next")
    }

    // MARK: - Finding 17: Home card after midnight

    // WHY: Home stays on screen while the app sleeps. Resumed the next
    // morning, the card showed yesterday ("already played", or yesterday's
    // set to play) until the player left Home.
    @Test("the Home card moves to the new day when iOS reports a day change")
    func homeCardFollowsDayChange() async {
        var now = Date(timeIntervalSince1970: 1_795_035_600) // 2026-11-18 20:00 UTC
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let network = MockNetworkService()
        let center = NotificationCenter()
        let model = DailyChallengeViewModel(network: network, now: { now }, calendar: utc, notificationCenter: center)
        await model.refreshToday(language: "sk")
        #expect(model.day.isoDate == "2026-11-18")

        now = now.addingTimeInterval(12 * 3600) // 2026-11-19 08:00
        center.post(name: UIApplication.significantTimeChangeNotification, object: nil)

        await pumpUntil({ network.capturedDailyFetchDate == "2026-11-19" }, "the card still asks for yesterday")
        #expect(model.day.isoDate == "2026-11-19")
        #expect(network.capturedDailyFetchLanguage == "sk")
    }

    // WHY: the round end's model shows a fixed day; a day change must not
    // move it to another challenge than the one just played.
    @Test("a day change does not move the round end's fixed day")
    func fixedDayIgnoresDayChange() async {
        var now = Date(timeIntervalSince1970: 1_795_035_600)
        let network = MockNetworkService()
        let center = NotificationCenter()
        let played = DailyChallengeDay(year: 2026, month: 11, day: 18)
        let model = DailyChallengeViewModel(network: network, now: { now }, day: played, notificationCenter: center)
        now = now.addingTimeInterval(12 * 3600)
        center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(network.fetchDailyChallengeCallCount == 0)
        #expect(model.day == played)
    }

    // MARK: - Finding 18: non-Gregorian calendar

    // WHY: with the Japanese or Buddhist calendar chosen in iOS Settings the
    // date went out as "8-10-15" or "2569-10-15"; the server answered 422 on
    // every day and the challenge could never be played.
    @Test("the challenge date is Gregorian whatever calendar the phone uses", arguments: [
        Calendar.Identifier.japanese, .buddhist, .islamicUmmAlQura, .hebrew,
    ])
    func gregorianDate(identifier: Calendar.Identifier) {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let instant = Date(timeIntervalSince1970: 1_792_058_400) // 2026-10-15 10:00 UTC
        #expect(DailyChallengeDay(instant, calendar: calendar).isoDate == "2026-10-15")
    }

    // WHY: the local day still follows the phone's time zone (a player in
    // Bratislava just after midnight plays the new day, not UTC's).
    @Test("the date stays local to the phone's time zone")
    func localTimeZoneKept() {
        var calendar = Calendar(identifier: .japanese)
        calendar.timeZone = TimeZone(identifier: "Europe/Bratislava")!
        let justAfterMidnight = Date(timeIntervalSince1970: 1_792_015_500) // 2026-10-14 22:05 UTC = 00:05 local
        #expect(DailyChallengeDay(justAfterMidnight, calendar: calendar).isoDate == "2026-10-15")
    }

    // MARK: - Finding 23: AI disclosure before a friend's link

    // WHY (App Review 5.1.2(i), #209): spoken answers go to AI services, and
    // the disclosure must come before first use. A friend's link on the
    // first launch skipped the onboarding page that shows it.
    @Test("a friend's link waits on the onboarding until the AI disclosure was accepted")
    func linkWaitsForConsent() throws {
        let defaults = try #require(UserDefaults(suiteName: "SharingAndDailyAuditFixTests.consent"))
        defaults.removePersistentDomain(forName: "SharingAndDailyAuditFixTests.consent")

        #expect(!SharedQuizInbox.mayOpen(isOnboardingShown: true, consentDefaults: defaults))
        // Players from before the disclosure existed never see the onboarding again.
        #expect(SharedQuizInbox.mayOpen(isOnboardingShown: false, consentDefaults: defaults))

        AIProcessingConsent.record(defaults: defaults)
        #expect(SharedQuizInbox.mayOpen(isOnboardingShown: true, consentDefaults: defaults))
        defaults.removePersistentDomain(forName: "SharingAndDailyAuditFixTests.consent")
    }

    // MARK: - Finding 24: update link in Trubbo Beta

    // WHY: since #234 every TestFlight build is Trubbo Beta. Its forced
    // update opened Trubbo's TestFlight page, which has no build for it, and
    // the tester stayed locked behind the update screen.
    @Test("Trubbo Beta's update opens Trubbo Beta in TestFlight; the App Store app keeps its links")
    func updateLinkPerApp() {
        #expect(UpdateRequiredView.storeURL(isTestFlight: true, isBeta: true)?.absoluteString
            == "itms-beta://beta.itunes.apple.com/v1/app/6834881608")
        #expect(UpdateRequiredView.storeURL(isTestFlight: true, isBeta: false)?.absoluteString
            == "itms-beta://beta.itunes.apple.com/v1/app/6762482437")
        #expect(UpdateRequiredView.storeURL(isTestFlight: false, isBeta: false)?.absoluteString
            == "https://apps.apple.com/app/id6762482437")
    }
}
