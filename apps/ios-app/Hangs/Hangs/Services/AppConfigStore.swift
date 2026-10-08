//
//  AppConfigStore.swift
//  Hangs
//
//  Server-side switches for shipped builds (#193 task 193.9 — beta hardening):
//  a forced update below a minimum version, pausing custom-pack orders, and a
//  short notice on Home, all changed with a backend env update instead of an
//  app release.
//
//  Fails open by design: until a fetch succeeds the app runs on
//  `RemoteAppConfig.permissive`, and a failed fetch keeps whatever was last
//  known. This endpoint must never be the reason someone cannot play.
//

import Combine
import Foundation
import os

@MainActor
final class AppConfigStore: ObservableObject {
    typealias Fetch = () async throws -> RemoteAppConfig

    @Published private(set) var config: RemoteAppConfig = .permissive
    @Published private var dismissedNotice: String?

    private static let dismissedNoticeKey = "dismissedAppNotice"

    private let fetch: Fetch
    private let defaults: UserDefaults
    private let appVersion: String
    private let languageCode: String

    /// The channel decides which minimum applies and where "update" leads.
    let isTestFlight: Bool

    var updateRequired: Bool {
        let minimum = isTestFlight ? config.minVersionTestflight : config.minVersionAppStore
        guard let minimum else { return false }
        return AppVersion.isOlder(appVersion, than: minimum)
    }

    var ordersEnabled: Bool { config.ordersEnabled }

    /// The notice to show on Home, nil once the player dismissed this text.
    /// A new text from the server shows again.
    var notice: String? {
        guard let text = config.notice?.text(for: languageCode), text != dismissedNotice else { return nil }
        return text
    }

    init(
        fetch: @escaping Fetch = AppConfigStore.liveFetch,
        defaults: UserDefaults = .standard,
        appVersion: String = AppVersion.current,
        isTestFlight: Bool = BuildChannel.isTestFlight(),
        languageCode: String = Bundle.main.preferredLocalizations.first ?? "en"
    ) {
        self.fetch = fetch
        self.defaults = defaults
        self.appVersion = appVersion
        self.isTestFlight = isTestFlight
        self.languageCode = languageCode
        #if DEBUG
            // UI tests run on a long-lived simulator: a notice dismissed in one
            // run must not hide it from the next.
            if UITestSupport.isUITesting { defaults.removeObject(forKey: Self.dismissedNoticeKey) }
        #endif
        dismissedNotice = defaults.string(forKey: Self.dismissedNoticeKey)
    }

    /// Best-effort fetch at launch and on every return to the foreground.
    func refresh() async {
        do {
            config = try await fetch()
        } catch {
            Logger.network.info("app-config fetch skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    func dismissNotice() {
        guard let text = config.notice?.text(for: languageCode) else { return }
        dismissedNotice = text
        defaults.set(text, forKey: Self.dismissedNoticeKey)
    }

    /// Short timeout: this runs at launch and must never hold anything up.
    static func liveFetch() async throws -> RemoteAppConfig {
        #if DEBUG
            if let seeded = debugSeed(arguments: CommandLine.arguments) { return seeded }
            if UITestSupport.isUITesting { return .permissive }
        #endif
        guard let url = URL(string: Config.apiBaseURLWithVersion + "/app-config") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RemoteAppConfig.self, from: data)
    }

    #if DEBUG
        /// Launch arguments that show each state on the simulator without a
        /// backend: `--app-config-update-required`, `--app-config-orders-off`,
        /// `--app-config-notice`.
        static func debugSeed(arguments: [String]) -> RemoteAppConfig? {
            let update = arguments.contains("--app-config-update-required")
            let ordersOff = arguments.contains("--app-config-orders-off")
            let notice = arguments.contains("--app-config-notice")
            guard update || ordersOff || notice else { return nil }
            return RemoteAppConfig(
                minVersionAppStore: update ? "999" : nil,
                minVersionTestflight: update ? "999" : nil,
                ordersEnabled: !ordersOff,
                notice: notice ? RemoteAppConfig.Notice(
                    sk: "Dnes od 22:00 prebieha údržba. Kvíz môže chvíľu nefungovať.",
                    cs: "Dnes od 22:00 probíhá údržba. Kvíz může chvíli nefungovat.",
                    en: "Maintenance tonight from 22:00. Quizzes may be unavailable for a while."
                ) : nil
            )
        }
    #endif
}
