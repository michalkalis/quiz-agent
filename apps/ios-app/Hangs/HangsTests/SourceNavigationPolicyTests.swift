//
//  SourceNavigationPolicyTests.swift
//  HangsTests
//
//  #190 — store listing readiness. Apple's age rating treats an in-app
//  browser with free navigation as "unrestricted web access" (pushes the app
//  to 18+). These tests pin the "source page only" rule: a regression here
//  silently re-opens the web and changes the App Store age rating.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Source viewer navigation policy")
struct SourceNavigationPolicyTests {
    private static let page = URL(string: "https://en.wikipedia.org/wiki/Paris")!
    private var page: URL { Self.page }
    private let other = URL(string: "https://example.com/elsewhere")!

    private func allows(
        _ url: URL,
        current: URL? = SourceNavigationPolicyTests.page,
        kind: SourceNavigationKind = .other,
        isMainFrame: Bool = true,
        opensNewWindow: Bool = false,
        initialLoadFinished: Bool = false
    ) -> Bool {
        SourceNavigationPolicy.allows(
            requestURL: url,
            currentURL: current,
            kind: kind,
            isMainFrame: isMainFrame,
            opensNewWindow: opensNewWindow,
            initialLoadFinished: initialLoadFinished
        )
    }

    @Test("The initial load and its server redirects are allowed")
    func initialLoadAndRedirects() {
        #expect(allows(page, current: nil))
        #expect(allows(other, current: page, kind: .other, initialLoadFinished: false))
    }

    @Test("Tapping a link to another page is blocked, so the viewer cannot browse")
    func linkTapBlocked() {
        #expect(!allows(other, kind: .linkActivated, initialLoadFinished: true))
        #expect(!allows(other, kind: .linkActivated, isMainFrame: false, initialLoadFinished: true))
    }

    @Test("Form posts and history navigation are blocked")
    func formsAndHistoryBlocked() {
        #expect(!allows(other, kind: .formSubmitted, initialLoadFinished: true))
        #expect(!allows(other, kind: .backForward, initialLoadFinished: true))
    }

    @Test("window.open and target=_blank never open a second page")
    func newWindowBlocked() {
        #expect(!allows(other, kind: .linkActivated, opensNewWindow: true))
        #expect(!allows(other, kind: .other, opensNewWindow: true))
        // Even the source URL itself: no extra window, ever.
        #expect(!allows(page, kind: .other, opensNewWindow: true))
    }

    @Test("A script-driven jump after the page loaded is blocked")
    func lateScriptNavigationBlocked() {
        #expect(!allows(other, kind: .other, initialLoadFinished: true))
    }

    @Test("Same-page anchor jumps are allowed, anchors on another page are not")
    func anchorJumps() {
        let anchor = URL(string: "https://en.wikipedia.org/wiki/Paris#History")!
        #expect(allows(anchor, kind: .linkActivated, initialLoadFinished: true))
        let foreignAnchor = URL(string: "https://example.com/elsewhere#top")!
        #expect(!allows(foreignAnchor, kind: .linkActivated, initialLoadFinished: true))
    }

    @Test("Non-web schemes in the main frame are blocked")
    func nonWebSchemesBlocked() throws {
        for raw in ["mailto:a@b.cz", "tel:123", "itms-apps://apps.apple.com/app/x", "javascript:alert(1)"] {
            let url = try #require(URL(string: raw))
            #expect(!allows(url, kind: .other, initialLoadFinished: false))
        }
    }

    @Test("Embedded iframes load, since they are part of the source page")
    func embeddedFramesAllowed() {
        #expect(allows(other, kind: .other, isMainFrame: false, initialLoadFinished: true))
    }

    @Test("Reload stays on the page")
    func reloadAllowed() {
        #expect(allows(page, kind: .reload, initialLoadFinished: true))
    }
}
