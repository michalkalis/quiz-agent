//
//  SharedQuizInbox.swift
//  Hangs
//
//  #232: a friend's quiz link waits here until Home can start it, whether it
//  was tapped (universal link) or pasted on the first launch after install.
//

import Combine
import Foundation
import UIKit

@MainActor
final class SharedQuizInbox: ObservableObject {
    /// A link waiting to start.
    @Published private(set) var token: String?
    /// Home shows the one quiet "Got a quiz link from a friend?" row.
    @Published private(set) var offersPaste = false
    /// The pasted text was no quiz link: the row asks to tap the link again.
    @Published private(set) var pasteMissed = false

    private let isFirstLaunch: Bool
    private let analytics: AnalyticsClient
    private let clipboardProbablyHasURL: () async -> Bool
    private var pasteOfferClosed = false

    private static let firstLaunchKey = "sharedQuiz.firstLaunchSeen"

    /// - Parameter isFirstLaunch: this run is the first after install (see `claimFirstLaunch`).
    init(
        isFirstLaunch: Bool,
        analytics: AnalyticsClient,
        clipboardProbablyHasURL: @escaping () async -> Bool = SharedQuizInbox.clipboardProbablyHasURL
    ) {
        self.isFirstLaunch = isFirstLaunch
        self.analytics = analytics
        self.clipboardProbablyHasURL = clipboardProbablyHasURL
    }

    /// True once per install: the first run of an app whose onboarding was
    /// never finished. A player who updates from an older build has finished
    /// it, so the paste row is for new installs only (founder 2026-11-14).
    static func claimFirstLaunch(defaults: UserDefaults = .standard, hasCompletedOnboarding: Bool) -> Bool {
        let seen = defaults.bool(forKey: firstLaunchKey)
        defaults.set(true, forKey: firstLaunchKey)
        return !seen && !hasCompletedOnboarding
    }

    /// True when `url` is a shared quiz link (it is then kept for Home).
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let token = SharedQuizLink.token(from: url) else { return false }
        self.token = token
        return true
    }

    /// A waiting link may start: the onboarding is not up, or its first page
    /// (the AI services disclosure, #209) was already accepted. Otherwise the
    /// link stays here until the onboarding finishes.
    static func mayOpen(isOnboardingShown: Bool, consentDefaults: UserDefaults = .standard) -> Bool {
        !isOnboardingShown || AIProcessingConsent.hasConsented(defaults: consentDefaults)
    }

    func take() -> String? {
        defer { token = nil }
        return token
    }

    /// Home is on screen: on the first launch only, ask iOS whether the
    /// clipboard probably holds a link. The question raises no paste alert;
    /// only the system Paste button reads the clipboard.
    func checkClipboard() async {
        guard isFirstLaunch, !pasteOfferClosed, !offersPaste else { return }
        let found = await clipboardProbablyHasURL()
        guard !pasteOfferClosed else { return }
        offersPaste = found
    }

    /// What the Paste button handed over: the first text that is exactly a
    /// `https://trubbo.app/play?s=…` link starts that quiz.
    func paste(_ texts: [String]) {
        if let token = texts.lazy.compactMap(SharedQuizLink.token(fromPasted:)).first {
            analytics.track(.sharedQuizPasted(outcome: .opened))
            closePasteOffer()
            self.token = token
        } else {
            analytics.track(.sharedQuizPasted(outcome: .notALink))
            pasteMissed = true
        }
    }

    /// The system Paste button's items: a URL or plain text (the play page
    /// copies the link as text).
    func paste(providers: [NSItemProvider]) async {
        var texts: [String] = []
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self), let url = await Self.loadURL(from: provider) {
                texts.append(url.absoluteString)
            } else if provider.canLoadObject(ofClass: String.self), let text = await Self.loadText(from: provider) {
                texts.append(text)
            }
        }
        paste(texts)
    }

    func dismissPasteOffer() {
        closePasteOffer()
    }

    /// The first quiz started: the row's moment has passed.
    func quizStarted() {
        closePasteOffer()
    }

    private func closePasteOffer() {
        pasteOfferClosed = true
        offersPaste = false
        pasteMissed = false
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }

    /// Off the main actor on purpose: iOS calls the `detectPatterns` handler
    /// on a background queue, and a handler that inherits this class's
    /// `@MainActor` traps there (the first-launch crash of build 87).
    nonisolated static func clipboardProbablyHasURL() async -> Bool {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings || pasteboard.hasURLs else { return false }
        return await withCheckedContinuation { continuation in
            pasteboard.detectPatterns(for: [.probableWebURL]) { @Sendable result in
                continuation.resume(returning: (try? result.get())?.contains(.probableWebURL) ?? false)
            }
        }
    }
}
