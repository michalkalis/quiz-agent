//
//  AppConfigStoreTests.swift
//  HangsTests
//
//  #193 task 193.9: server switches for shipped builds. Why these matter: a
//  forced update blocks play, and builds already in players' hands can never
//  receive a fix to this logic. So a version compare that gets "1.10" vs "1.9"
//  wrong, or a fetch failure that does anything but leave the app usable,
//  would lock real players out with no way back except a server change.
//

import Foundation
@testable import Hangs
import Testing

@Suite("Remote app config (#193 task 193.9)")
@MainActor
struct AppConfigStoreTests {
    private struct Offline: Error {}

    // MARK: Version comparison

    @Test("Versions compare numerically per component, not as text", arguments: [
        ("1.9", "1.10", true),
        ("1.10", "1.9", false),
        ("1.2", "1.2.0", false),
        ("1.2.0", "1.2", false),
        ("1.2", "1.2.1", true),
        ("2.0", "1.99.99", false),
        ("1", "2", true),
    ])
    func testNumericComparison(version: String, minimum: String, isOlder: Bool) {
        #expect(AppVersion.isOlder(version, than: minimum) == isOlder)
    }

    @Test("An unreadable version on either side never counts as older", arguments: [
        ("", "1.0"),
        ("1.0", ""),
        ("1.0-beta", "2.0"),
        ("1.0", "v2"),
        ("1..0", "2.0"),
    ])
    func testUnreadableVersionFailsOpen(version: String, minimum: String) {
        #expect(!AppVersion.isOlder(version, than: minimum))
    }

    // MARK: Fail open

    @Test("Before any fetch the app is fully usable")
    func testDefaultsArePermissive() {
        let store = makeStore(version: "1.0") { throw Offline() }
        #expect(!store.updateRequired)
        #expect(store.ordersEnabled)
        #expect(store.notice == nil)
    }

    @Test("A failed fetch leaves the app usable")
    func testNetworkErrorFailsOpen() async {
        let store = makeStore(version: "1.0") { throw URLError(.timedOut) }
        await store.refresh()
        #expect(!store.updateRequired)
        #expect(store.ordersEnabled)
    }

    @Test("A config body without the new keys decodes to permissive defaults")
    func testMissingKeysDecodePermissive() throws {
        let config = try JSONDecoder().decode(RemoteAppConfig.self, from: Data("{}".utf8))
        #expect(config == .permissive)
    }

    // MARK: Switches

    @Test("Below the channel's minimum the update is required, at or above it is not")
    func testMinimumPerChannel() async {
        let config = RemoteAppConfig(
            minVersionAppStore: "1.3",
            minVersionTestflight: "1.5",
            ordersEnabled: true,
            notice: nil
        )
        let appStore = makeStore(version: "1.4") { config }
        let testFlight = makeStore(version: "1.4", isTestFlight: true) { config }
        await appStore.refresh()
        await testFlight.refresh()
        #expect(!appStore.updateRequired)
        #expect(testFlight.updateRequired)
    }

    @Test("Backend JSON drives orders and the notice in the UI language")
    func testDecodesBackendResponse() async throws {
        let json = """
        {"min_version_app_store": null, "min_version_testflight": null,
         "orders_enabled": false,
         "notice": {"sk": "Údržba dnes večer.", "cs": null, "en": "Maintenance tonight."}}
        """
        let decoded = try JSONDecoder().decode(RemoteAppConfig.self, from: Data(json.utf8))
        let slovak = makeStore(version: "1.0", language: "sk") { decoded }
        let czech = makeStore(version: "1.0", language: "cs") { decoded }
        await slovak.refresh()
        await czech.refresh()
        #expect(!slovak.ordersEnabled)
        #expect(slovak.notice == "Údržba dnes večer.")
        // No Czech text: English stands in rather than hiding the notice.
        #expect(czech.notice == "Maintenance tonight.")
    }

    @Test("A dismissed notice stays hidden across launches until the text changes")
    func testDismissedNoticeIsRemembered() async {
        let defaults = UserDefaults(suiteName: "AppConfigStoreTests.\(UUID().uuidString)")!
        var text = "Maintenance tonight."
        let fetch: AppConfigStore.Fetch = {
            RemoteAppConfig(
                minVersionAppStore: nil,
                minVersionTestflight: nil,
                ordersEnabled: true,
                notice: .init(sk: nil, cs: nil, en: text)
            )
        }
        let first = makeStore(version: "1.0", defaults: defaults, fetch: fetch)
        await first.refresh()
        first.dismissNotice()
        #expect(first.notice == nil)

        let relaunch = makeStore(version: "1.0", defaults: defaults, fetch: fetch)
        await relaunch.refresh()
        #expect(relaunch.notice == nil)

        text = "New notice."
        await relaunch.refresh()
        #expect(relaunch.notice == "New notice.")
    }

    private func makeStore(
        version: String,
        isTestFlight: Bool = false,
        language: String = "en",
        defaults: UserDefaults? = nil,
        fetch: @escaping AppConfigStore.Fetch
    ) -> AppConfigStore {
        AppConfigStore(
            fetch: fetch,
            defaults: defaults ?? UserDefaults(suiteName: "AppConfigStoreTests.\(UUID().uuidString)")!,
            appVersion: version,
            isTestFlight: isTestFlight,
            languageCode: language
        )
    }
}
