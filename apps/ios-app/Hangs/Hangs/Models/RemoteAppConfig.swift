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
    /// #204.9: the voice-settings experiment; nil when the server has none or
    /// sent something unreadable, and then every switch stays manual.
    let voiceExperiment: VoiceExperimentConfig?
    /// #205: the daily challenge card on Home. Off unless the server says on,
    /// also in `permissive`: a missing key must never show a card whose
    /// endpoints answer 404.
    let dailyChallengeEnabled: Bool
    /// #214: builds below this get a dismissible "new version" card on Home.
    let recommendedVersionAppStore: String?
    let recommendedVersionTestflight: String?
    /// #214: a full-screen maintenance message over the whole app. Off unless
    /// the server says on; the message is optional (default copy otherwise).
    let maintenanceEnabled: Bool
    let maintenanceMessage: Notice?

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
        case voiceExperiment = "voice_experiment"
        case dailyChallengeEnabled = "daily_challenge_enabled"
        case recommendedVersionAppStore = "recommended_version_app_store"
        case recommendedVersionTestflight = "recommended_version_testflight"
        case maintenanceEnabled = "maintenance_enabled"
        case maintenanceMessage = "maintenance_message"
    }

    init(
        minVersionAppStore: String?,
        minVersionTestflight: String?,
        ordersEnabled: Bool,
        notice: Notice?,
        voiceExperiment: VoiceExperimentConfig? = nil,
        dailyChallengeEnabled: Bool = false,
        recommendedVersionAppStore: String? = nil,
        recommendedVersionTestflight: String? = nil,
        maintenanceEnabled: Bool = false,
        maintenanceMessage: Notice? = nil
    ) {
        self.minVersionAppStore = minVersionAppStore
        self.minVersionTestflight = minVersionTestflight
        self.ordersEnabled = ordersEnabled
        self.notice = notice
        self.voiceExperiment = voiceExperiment
        self.dailyChallengeEnabled = dailyChallengeEnabled
        self.recommendedVersionAppStore = recommendedVersionAppStore
        self.recommendedVersionTestflight = recommendedVersionTestflight
        self.maintenanceEnabled = maintenanceEnabled
        self.maintenanceMessage = maintenanceMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minVersionAppStore = try container.decodeIfPresent(String.self, forKey: .minVersionAppStore)
        minVersionTestflight = try container.decodeIfPresent(String.self, forKey: .minVersionTestflight)
        ordersEnabled = try container.decodeIfPresent(Bool.self, forKey: .ordersEnabled) ?? true
        notice = try container.decodeIfPresent(Notice.self, forKey: .notice)
        // Never the reason the rest of the config is lost.
        voiceExperiment = try? container.decodeIfPresent(VoiceExperimentConfig.self, forKey: .voiceExperiment)
        dailyChallengeEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .dailyChallengeEnabled)) ?? false
        recommendedVersionAppStore = try? container.decodeIfPresent(String.self, forKey: .recommendedVersionAppStore)
        recommendedVersionTestflight = try? container.decodeIfPresent(String.self, forKey: .recommendedVersionTestflight)
        maintenanceEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .maintenanceEnabled)) ?? false
        maintenanceMessage = try? container.decodeIfPresent(Notice.self, forKey: .maintenanceMessage)
    }
}
