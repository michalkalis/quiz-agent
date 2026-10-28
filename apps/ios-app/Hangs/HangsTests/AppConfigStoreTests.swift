//
//  AppConfigStoreTests.swift
//  HangsTests
//
//  #193 task 193.9: server switches for shipped builds. Why these matter: a
//  forced update blocks play, and builds already in players' hands can never
//  receive a fix to this logic. So a version compare that gets "1.10" vs "1.9"
//  wrong, or a fetch failure that does anything but leave the app usable,
//  would lock real players out with no way back except a server change.
//  #214 adds the optional update card and the maintenance screen: both reach
//  every installed build too, so the nudge must never block and maintenance
//  must end on its own when the server switch goes off.
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
    func numericComparison(version: String, minimum: String, isOlder: Bool) {
        #expect(AppVersion.isOlder(version, than: minimum) == isOlder)
    }

    @Test("An unreadable version on either side never counts as older", arguments: [
        ("", "1.0"),
        ("1.0", ""),
        ("1.0-beta", "2.0"),
        ("1.0", "v2"),
        ("1..0", "2.0"),
    ])
    func unreadableVersionFailsOpen(version: String, minimum: String) {
        #expect(!AppVersion.isOlder(version, than: minimum))
    }

    // MARK: Fail open

    @Test("Before any fetch the app is fully usable")
    func defaultsArePermissive() {
        let store = makeStore(version: "1.0") { throw Offline() }
        #expect(!store.updateRequired)
        #expect(store.ordersEnabled)
        #expect(store.notice == nil)
    }

    @Test("A failed fetch leaves the app usable")
    func networkErrorFailsOpen() async {
        let store = makeStore(version: "1.0") { throw URLError(.timedOut) }
        await store.refresh()
        #expect(!store.updateRequired)
        #expect(store.ordersEnabled)
    }

    @Test("A config body without the new keys decodes to permissive defaults")
    func missingKeysDecodePermissive() throws {
        let config = try JSONDecoder().decode(RemoteAppConfig.self, from: Data("{}".utf8))
        #expect(config == .permissive)
    }

    // MARK: Switches

    @Test("Below the channel's minimum the update is required, at or above it is not")
    func minimumPerChannel() async {
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
    func decodesBackendResponse() async throws {
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
    func dismissedNoticeIsRemembered() async {
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

    // MARK: Update nudge and maintenance (#214)

    @Test("Below the recommended version the card shows until dismissed, and a newer recommendation shows it again")
    func updateNudgeDismissPerVersion() async {
        let defaults = UserDefaults(suiteName: "AppConfigStoreTests.\(UUID().uuidString)")!
        var recommended = "1.2"
        let fetch: AppConfigStore.Fetch = {
            RemoteAppConfig(
                minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil,
                recommendedVersionAppStore: recommended
            )
        }
        let store = makeStore(version: "1.1", defaults: defaults, fetch: fetch)
        await store.refresh()
        #expect(store.updateRecommended)
        #expect(!store.updateRequired)

        store.dismissUpdate()
        let relaunch = makeStore(version: "1.1", defaults: defaults, fetch: fetch)
        await relaunch.refresh()
        #expect(!relaunch.updateRecommended)

        recommended = "1.3"
        await relaunch.refresh()
        #expect(relaunch.updateRecommended)
    }

    @Test("The nudge follows the build's channel and never shows next to the forced update")
    func updateNudgePerChannelAndUnderForcedUpdate() async {
        let config = RemoteAppConfig(
            minVersionAppStore: "1.5", minVersionTestflight: nil, ordersEnabled: true, notice: nil,
            recommendedVersionAppStore: "1.6", recommendedVersionTestflight: "1.4"
        )
        let appStore = makeStore(version: "1.4") { config }
        let testFlight = makeStore(version: "1.4", isTestFlight: true) { config }
        await appStore.refresh()
        await testFlight.refresh()
        #expect(appStore.updateRequired)
        #expect(!appStore.updateRecommended)
        // Already at the TestFlight recommendation: nothing to nudge.
        #expect(!testFlight.updateRecommended)
    }

    @Test("Maintenance decodes from the backend with its message, and the forced update wins over it")
    func maintenanceFromBackend() async throws {
        let json = """
        {"maintenance_enabled": true,
         "maintenance_message": {"sk": "Späť o 10:00.", "cs": null, "en": "Back at 10:00."}}
        """
        let decoded = try JSONDecoder().decode(RemoteAppConfig.self, from: Data(json.utf8))
        let slovak = makeStore(version: "1.0", language: "sk") { decoded }
        await slovak.refresh()
        #expect(slovak.maintenance)
        #expect(slovak.maintenanceMessage == "Späť o 10:00.")

        let outdated = RemoteAppConfig(
            minVersionAppStore: "2.0", minVersionTestflight: nil, ordersEnabled: true, notice: nil,
            maintenanceEnabled: true
        )
        let blocked = makeStore(version: "1.0") { outdated }
        await blocked.refresh()
        // The update screen is the only way out for this build; maintenance must not hide it.
        #expect(blocked.updateRequired)
        #expect(!blocked.maintenance)
    }

    @Test("The maintenance screen lets the app continue once the server switch goes off")
    func maintenanceEndsOnItsOwn() async {
        var enabled = true
        var fetches = 0
        let store = makeStore(version: "1.0") {
            fetches += 1
            if fetches == 3 { enabled = false }
            return RemoteAppConfig(
                minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil,
                maintenanceEnabled: enabled
            )
        }
        await store.refresh()
        #expect(store.maintenance)

        await store.recheckUntilMaintenanceEnds(every: .zero)
        #expect(!store.maintenance)
        #expect(fetches == 3)
    }

    @Test("Maintenance stays on while the server is unreachable, it never flips off by itself")
    func maintenanceSurvivesFailedFetch() async {
        var online = true
        let store = makeStore(version: "1.0") {
            guard online else { throw URLError(.cannotConnectToHost) }
            return RemoteAppConfig(
                minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil,
                maintenanceEnabled: true
            )
        }
        await store.refresh()
        online = false
        await store.refresh()
        #expect(store.maintenance)
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
