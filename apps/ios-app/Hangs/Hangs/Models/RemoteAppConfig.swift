//
//  RemoteAppConfig.swift
//  Hangs
//
//  Server-side switches for shipped builds (#193 task 193.9 — beta hardening).
//

import Foundation

/// `GET /api/v1/app-config`. Mirrors `AppConfigResponse` in
/// `apps/quiz-agent/app/api/routes/app_config.py`.
///
/// Every field decodes leniently (missing → permissive) so a server that adds
/// or drops a key can never turn into a forced update or a hidden feature.
nonisolated struct RemoteAppConfig: Codable, Sendable, Equatable {
    /// A short message per UI language; any of them may be absent.
    struct Notice: Codable, Sendable, Equatable {
        let sk: String?
        let cs: String?
        let en: String?

        /// The text for `languageCode`, else English, else whichever exists.
        func text(for languageCode: String) -> String? {
            let preferred = switch languageCode {
            case "sk": sk
            case "cs": cs
            default: en
            }
            return [preferred, en, sk, cs].lazy.compactMap { $0 }.first { !$0.isEmpty }
        }
    }

    let minVersionAppStore: String?
    let minVersionTestflight: String?
    let ordersEnabled: Bool
    let notice: Notice?

    /// What the app assumes until (or unless) a fetch succeeds.
    static let permissive = RemoteAppConfig(
        minVersionAppStore: nil,
        minVersionTestflight: nil,
        ordersEnabled: true,
        notice: nil
    )

    enum CodingKeys: String, CodingKey {
        case minVersionAppStore = "min_version_app_store"
        case minVersionTestflight = "min_version_testflight"
        case ordersEnabled = "orders_enabled"
        case notice
    }

    init(minVersionAppStore: String?, minVersionTestflight: String?, ordersEnabled: Bool, notice: Notice?) {
        self.minVersionAppStore = minVersionAppStore
        self.minVersionTestflight = minVersionTestflight
        self.ordersEnabled = ordersEnabled
        self.notice = notice
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minVersionAppStore = try container.decodeIfPresent(String.self, forKey: .minVersionAppStore)
        minVersionTestflight = try container.decodeIfPresent(String.self, forKey: .minVersionTestflight)
        ordersEnabled = try container.decodeIfPresent(Bool.self, forKey: .ordersEnabled) ?? true
        notice = try container.decodeIfPresent(Notice.self, forKey: .notice)
    }
}
