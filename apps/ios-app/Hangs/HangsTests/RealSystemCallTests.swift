//
//  RealSystemCallTests.swift
//  HangsTests
//
//  #235.4: every other test swaps these system calls for a closure, so the
//  real call first ran on a tester's phone. That is how the clipboard check
//  crashed the first launch of build 87: iOS answered off the main thread and
//  the handler had inherited `@MainActor`. Each test here runs the REAL call
//  once on the simulator, so a handler that traps on the thread iOS uses, or
//  a continuation that is never resumed, fails here instead. The inventory and
//  the device-only calls: docs/testing/system-calls-coverage.md.
//
//  Calls that would raise a permission prompt run only once the simulator has
//  an answer stored (a fresh CI simulator has none), and are skipped visibly
//  otherwise; nothing here records or plays sound.
//

import AVFoundation
import Foundation
@testable import Hangs
import LinkPresentation
import Speech
import Testing
import UIKit
import WebKit

@Suite("Real system calls (#235.4)", .serialized)
@MainActor
struct RealSystemCallTests {
    private static let token = "Ab3_k9-ZxQ"
    private static let link = "https://trubbo.app/play?s=\(token)"

    private nonisolated static var micAnswered: Bool { AVAudioApplication.shared.recordPermission != .undetermined }
    private nonisolated static var speechAnswered: Bool { SFSpeechRecognizer.authorizationStatus() != .notDetermined }

    // MARK: - Pasteboard / NSItemProvider

    @Test("a link handed over by the system Paste button loads through the real item provider")
    func pastedItemProvidersLoad() async {
        // The Paste button hands over NSItemProviders that iOS loads on its
        // own queue; a stuck or trapping load is a paste that never starts the
        // friend's quiz.
        let inbox = SharedQuizInbox(isFirstLaunch: true, analytics: MockAnalyticsClient(), clipboardProbablyHasURL: { false })

        await inbox.paste(providers: [NSItemProvider(object: URL(string: Self.link)! as NSURL)])
        #expect(inbox.take() == Self.token, "a copied URL starts the quiz")

        await inbox.paste(providers: [NSItemProvider(object: Self.link as NSString)])
        #expect(inbox.take() == Self.token, "the play page copies the link as plain text")
    }

    // MARK: - Permissions

    @Test(
        "the real microphone permission request answers without trapping",
        .enabled(if: micAnswered, "a fresh simulator would show the permission prompt"),
        .timeLimit(.minutes(1))
    )
    func microphonePermissionRequest() async {
        // Onboarding, the first answer and dictation all await this; iOS may
        // answer on another thread (AVAudioApplication.h).
        let granted = await AudioService().requestMicrophonePermission()
        #expect(granted == (AVAudioApplication.shared.recordPermission == .granted))
    }

    @Test(
        "the real speech-recognition permission request answers without trapping",
        .enabled(if: speechAnswered, "a fresh simulator would show the permission prompt"),
        .timeLimit(.minutes(1))
    )
    func speechPermissionRequest() async {
        // #237: asked only when the player turns voice commands on.
        let status = await SilenceDetectionService.requestSystemAuthorization()
        #expect(status == SFSpeechRecognizer.authorizationStatus())
    }

    @Test("launch and every listening window read the real speech permission without asking")
    func speechPermissionStatusRead() {
        // #237: runs on a fresh simulator too. Had this read raised the
        // prompt, the run would hang on the alert instead of answering.
        #expect(SilenceDetectionService().authorizationStatusProvider() == SFSpeechRecognizer.authorizationStatus())
    }

    // MARK: - Sign in with Apple

    @Test("the launch check of a stored Apple sign-in survives the real credential lookup", .timeLimit(.minutes(1)))
    func appleCredentialStateCheck() async {
        // Runs at every cold launch of a signed-in player. An Apple ID this
        // device never signed in with is not found: the player drops to a
        // fresh anonymous identity (offline here, so the stored one is gone).
        let store = SingleTokenStore(AuthTokens(
            accessToken: "a", refreshToken: "r", anonId: "user-1",
            accountName: nil, accountEmail: nil, appleUserId: "000000.0000000000000000000000000000.0000"
        ))
        let auth = AuthService(baseURL: "http://test.invalid", session: OfflineURLProtocol.session(), store: store)

        await auth.checkAppleCredentialState()

        #expect(store.load() == nil)
    }

    // MARK: - Network and calls

    @Test("the real network path check answers once and returns", .timeLimit(.minutes(1)))
    func networkPathCheck() async {
        // "Games on this Wi-Fi" waits on it; a continuation that is never
        // resumed would leave the Together screen loading forever. The
        // answer itself depends on the Mac's network, so only its arrival is
        // asserted (the time limit).
        _ = await LocalNetworkCheck.isOffCellular()
    }

    @Test("the real call observer reads no call on the simulator")
    func callObserverRead() {
        // Leaving the app for a call is not "left during a question" (#212.4).
        #expect(CallMonitor().isOnCall == false)
    }

    // MARK: - Audio session

    @Test(
        "the real audio session accepts the quiz configuration",
        .enabled(if: micAnswered, "activating a recording session may prompt for the microphone")
    )
    func quizAudioSessionConfiguration() throws {
        // Every quiz start configures and activates the shared session and
        // registers the route-change and interruption observers on the real
        // notification center. iOS rejects (throws) or silently drops an
        // option it does not allow in a category; a dropped Bluetooth option
        // is a car that hears nothing. (The simulator posts no route change
        // for a category switch, so the observers' delivery stays device-only.)
        let service = AudioService()
        defer { service.deactivateSession() }

        try service.setupAudioSession(mode: .default)

        // What the service applied after fitting the mic to the route (#204.4).
        let expected = try #require(service.appliedSessionConfiguration)
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == expected.category)
        #expect(session.mode == expected.mode)
        #expect(session.categoryOptions == expected.options)
    }

    // MARK: - Share sheet

    @Test("the real share sheet reads the shared quiz's preview without trapping", .timeLimit(.minutes(1)))
    func shareSheetReadsPreview() async throws {
        // Sharing a quiz hands ShareLinkItem to UIKit, which asks it for the
        // header (title, link, icon) on a thread it does not document. The
        // probe has ShareLinkItem's shape (main-actor class, Objective-C
        // methods iOS calls) and forwards to the real item, so it also tells
        // whether iOS asked at all.
        let item = ShareLinkItem(url: URL(string: Self.link)!, title: "Quiz")
        let probe = ShareItemProbe(item)

        ShareSheetPresenter.present([probe])
        let sheet = try #require(await Self.waitFor { Self.topmost() as? UIActivityViewController })
        defer { sheet.dismiss(animated: false) }

        let asked = await Self.waitFor { probe.previewAsked ? true : nil }
        #expect(asked == true, "iOS reads the header from the item's link metadata")
    }

    // MARK: - Web view

    @Test("the source page loads through the real web view navigation delegate", .timeLimit(.minutes(1)))
    func sourcePageNavigationDelegate() async throws {
        // A question's source opens in a web view whose delegate decides every
        // navigation; WebKit calls it on the main thread. A policy that
        // refused the first load would be a blank source page.
        let coordinator = WebViewRepresentable.Coordinator()
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = coordinator

        webView.loadHTMLString("<title>Paris</title><p>Paris</p>", baseURL: URL(string: "https://en.wikipedia.org/wiki/Paris"))

        let title = await Self.waitFor { webView.title?.isEmpty == false ? webView.title : nil }
        #expect(title == "Paris")
    }

    // MARK: - Helpers

    private static func topmost() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// Real system UI settles on its own clock: poll in short real-time steps,
    /// bounded (10 s), instead of a fixed sleep.
    private static func waitFor<T>(_ probe: () -> T?) async -> T? {
        for _ in 0 ..< 200 {
            if let value = probe() { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return probe()
    }
}

/// Forwards to the real item and notes the header request.
private final class ShareItemProbe: NSObject, UIActivityItemSource {
    private let item: ShareLinkItem
    private(set) var previewAsked = false

    init(_ item: ShareLinkItem) { self.item = item }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        item.activityViewControllerPlaceholderItem(controller)
    }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        item.activityViewController(controller, itemForActivityType: type)
    }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        previewAsked = true
        return item.activityViewControllerLinkMetadata(controller)
    }
}

/// The Keychain stand-in: one stored session, readable after the check.
private final nonisolated class SingleTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?

    init(_ tokens: AuthTokens) { self.tokens = tokens }

    func load() -> AuthTokens? { lock.withLock { tokens } }
    func save(_ tokens: AuthTokens) { lock.withLock { self.tokens = tokens } }
    func clear() { lock.withLock { tokens = nil } }
}

/// Every request fails at once as offline, so the fresh-identity bootstrap
/// after a dropped sign-in never reaches a server.
private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override nonisolated init(request: URLRequest, cachedResponse: CachedURLResponse?, client: (any URLProtocolClient)?) {
        super.init(request: request, cachedResponse: cachedResponse, client: client)
    }

    override nonisolated class func canInit(with _: URLRequest) -> Bool { true }
    override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override nonisolated func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override nonisolated func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
