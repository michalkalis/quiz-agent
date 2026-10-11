//
//  LegalPageURLTests.swift
//  HangsTests
//
//  Privacy policy and terms links (Settings, paywall) must open the pages on
//  trubbo.app in the app's language: App Review requires working links for
//  auto-renewable subscriptions, and the App Store listing uses the same URLs
//  per locale. The API server no longer serves legal pages.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Legal page URLs on trubbo.app")
struct LegalPageURLTests {
    @Test("Slovak and Czech open their language variant", arguments: ["sk", "cs"])
    func localizedVariant(language: String) {
        #expect(Config.legalPageURL("privacy", languageCode: language).absoluteString
            == "https://trubbo.app/\(language)/privacy")
        #expect(Config.legalPageURL("terms", languageCode: language).absoluteString
            == "https://trubbo.app/\(language)/terms")
    }

    @Test("English and any other language open the English page at the root", arguments: ["en", "de"])
    func englishDefault(language: String) {
        #expect(Config.legalPageURL("privacy", languageCode: language).absoluteString == "https://trubbo.app/privacy")
        #expect(Config.legalPageURL("terms", languageCode: language).absoluteString == "https://trubbo.app/terms")
    }
}
