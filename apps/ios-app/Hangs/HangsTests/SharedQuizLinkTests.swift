//
//  SharedQuizLinkTests.swift
//  HangsTests
//
//  #232 share a quiz by link, the friend's way in. Why each rule matters:
//  - only our own https://trubbo.app/play?s= links may start a quiz: a pasted
//    or tapped look-alike (other host, http, a sentence around the link)
//    must not reach the server as a token;
//  - the paste row is for the first launch after install only (founder
//    2026-11-14): a player updating from an older build never sees it, and
//    the row is gone after ✕ or the first quiz;
//  - the server's refusal codes map to the notice the player reads.
//

import Foundation
@testable import Hangs
import Testing
import UIKit

@Suite("Shared quiz link (#232)")
@MainActor
struct SharedQuizLinkTests {
    private static let token = "Ab3_k9-ZxQ"

    @Test("a play link round-trips to its token")
    func roundTrip() throws {
        let url = SharedQuizLink.url(token: Self.token)
        #expect(url.absoluteString == "https://trubbo.app/play?s=\(Self.token)")
        #expect(SharedQuizLink.token(from: url) == Self.token)
    }

    @Test(
        "anything but our https play link is no quiz link",
        arguments: [
            "http://trubbo.app/play?s=Ab3_k9-ZxQ",
            "https://evil.example/play?s=Ab3_k9-ZxQ",
            "https://trubbo.app/join?t=Ab3_k9-ZxQ",
            "https://trubbo.app/play?s=short",
            "https://trubbo.app/play?s=Ab3%20k9ZxQ",
            "https://trubbo.app/play",
        ]
    )
    func rejectsOthers(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(SharedQuizLink.token(from: url) == nil)
    }

    @Test("a pasted link may carry spaces around it, never a sentence")
    func pastedText() {
        #expect(SharedQuizLink.token(fromPasted: "  https://trubbo.app/play?s=\(Self.token)\n") == Self.token)
        #expect(SharedQuizLink.token(fromPasted: "Play my quiz https://trubbo.app/play?s=\(Self.token)") == nil)
        #expect(SharedQuizLink.token(fromPasted: "hello") == nil)
    }

    @Test("the server's refusals read as the right notice")
    func unavailableMapping() {
        #expect(SharedQuizUnavailable(statusCode: 404, code: "not_found") == .notFound)
        #expect(SharedQuizUnavailable(statusCode: 409, code: "already_played") == .alreadyPlayed)
        #expect(SharedQuizUnavailable(statusCode: 409, code: "daily_played_other_language") == .alreadyPlayed)
        #expect(SharedQuizUnavailable(statusCode: 409, code: "nothing_playable") == .nothingPlayable)
        #expect(SharedQuizUnavailable(statusCode: 409, code: "pack_not_finished") == .notShareable)
    }

    // MARK: - First launch and the paste row

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "shared-quiz-\(UUID().uuidString)"))
    }

    @Test("only the first launch of a new install counts, once")
    func firstLaunchOnce() throws {
        let defaults = try freshDefaults()
        #expect(SharedQuizInbox.claimFirstLaunch(defaults: defaults, hasCompletedOnboarding: false))
        #expect(!SharedQuizInbox.claimFirstLaunch(defaults: defaults, hasCompletedOnboarding: false), "the second launch is not first")
    }

    @Test("a player updating from an older build is no new install")
    func updateIsNotFirstLaunch() throws {
        #expect(try !SharedQuizInbox.claimFirstLaunch(defaults: freshDefaults(), hasCompletedOnboarding: true))
    }

    @Test("the row shows on the first launch while a link probably waits, else never")
    func rowNeedsFirstLaunchAndALink() async {
        let first = SharedQuizInbox(isFirstLaunch: true, analytics: MockAnalyticsClient(), clipboardProbablyHasURL: { true })
        await first.checkClipboard()
        #expect(first.offersPaste)

        let noLink = SharedQuizInbox(isFirstLaunch: true, analytics: MockAnalyticsClient(), clipboardProbablyHasURL: { false })
        await noLink.checkClipboard()
        #expect(!noLink.offersPaste)

        var asked = false
        let later = SharedQuizInbox(isFirstLaunch: false, analytics: MockAnalyticsClient(), clipboardProbablyHasURL: { asked = true; return true })
        await later.checkClipboard()
        #expect(!later.offersPaste)
        #expect(!asked, "a later launch must not even ask iOS about the clipboard")
    }

    /// Every other test swaps the clipboard check for a closure, so the real
    /// one never ran: iOS answers it off the main thread, and that crashed
    /// the very first launch after install (build 87, a new player's first
    /// second in the app).
    @Test("the real clipboard check survives iOS answering off the main thread")
    func realClipboardCheckDoesNotCrash() async {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.items
        defer { pasteboard.items = before }

        pasteboard.string = "https://trubbo.app/play?s=\(Self.token)"
        #expect(await SharedQuizInbox.clipboardProbablyHasURL())

        pasteboard.items = []
        #expect(await !SharedQuizInbox.clipboardProbablyHasURL())
    }

    @Test("a pasted quiz link starts it, is counted, and the row goes")
    func pasteOpens() async {
        let analytics = MockAnalyticsClient()
        let inbox = SharedQuizInbox(isFirstLaunch: true, analytics: analytics, clipboardProbablyHasURL: { true })
        await inbox.checkClipboard()

        inbox.paste(["https://trubbo.app/play?s=\(Self.token)"])

        #expect(inbox.take() == Self.token)
        #expect(!inbox.offersPaste)
        #expect(analytics.events(named: "shared_quiz_pasted") == [.sharedQuizPasted(outcome: .opened)])
    }

    @Test("other pasted text keeps the row with a hint and starts nothing")
    func pasteMisses() async {
        let analytics = MockAnalyticsClient()
        let inbox = SharedQuizInbox(isFirstLaunch: true, analytics: analytics, clipboardProbablyHasURL: { true })
        await inbox.checkClipboard()

        inbox.paste(["https://example.com/something"])

        #expect(inbox.take() == nil)
        #expect(inbox.offersPaste)
        #expect(inbox.pasteMissed)
        #expect(analytics.events(named: "shared_quiz_pasted") == [.sharedQuizPasted(outcome: .notALink)])
    }

    @Test("✕ or the first quiz closes the row for good")
    func rowCloses() async {
        let dismissed = SharedQuizInbox(isFirstLaunch: true, analytics: MockAnalyticsClient(), clipboardProbablyHasURL: { true })
        await dismissed.checkClipboard()
        dismissed.dismissPasteOffer()
        await dismissed.checkClipboard()
        #expect(!dismissed.offersPaste, "Home appearing again must not bring it back")

        let played = SharedQuizInbox(isFirstLaunch: true, analytics: MockAnalyticsClient(), clipboardProbablyHasURL: { true })
        await played.checkClipboard()
        played.quizStarted()
        await played.checkClipboard()
        #expect(!played.offersPaste)
    }

    @Test("a tapped quiz link waits for Home; other links are left to others")
    func receive() throws {
        let inbox = SharedQuizInbox(isFirstLaunch: false, analytics: MockAnalyticsClient())
        #expect(try !inbox.receive(#require(URL(string: "https://trubbo.app/join?t=abcdefgh"))))
        #expect(inbox.receive(SharedQuizLink.url(token: Self.token)))
        #expect(inbox.take() == Self.token)
        #expect(inbox.take() == nil, "a link starts once")
    }
}
