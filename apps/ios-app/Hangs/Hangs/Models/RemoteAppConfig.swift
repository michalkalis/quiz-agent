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
        /// #231: the server omits `uk` while it has no Ukrainian text.
        let uk: String?

        /// The text for `languageCode`, else English, else whichever exists.
        /// Ukrainian is never the stand-in for another language: a Slovak
        /// player reads English sooner than Cyrillic.
        func text(for languageCode: String) -> String? {
            let preferred = switch languageCode {
            case "sk": sk
            case "cs": cs
            case "uk": uk
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
    /// #212: the Together button on Home (same-room multiplayer). Off unless
    /// the server says on, also in `permissive`: the room endpoints answer 404
    /// while the server switch is off.
    let multiplayerEnabled: Bool
    /// #217: the App Store build shows Together only when this is also on
    /// (TestFlight builds ignore it). Off unless the server says on.
    let multiplayerEnabledAppStore: Bool
    /// #232: share a quiz by link (send, open, paste, compare, a pack in a
    /// game together). Off unless the server says on, also in `permissive`:
    /// the shared-quiz endpoints answer 404 while the server switch is off.
    let sharedQuizEnabled: Bool
    /// #236: family mode „S deťmi“ on Home. TestFlight builds read
    /// `familyModeEnabled`; the App Store build needs `familyModeEnabledAppStore`
    /// too. Off unless the server says on, also in `permissive`.
    let familyModeEnabled: Bool
    let familyModeEnabledAppStore: Bool
    /// #236: App Store countries (StoreKit `Storefront.countryCode`, alpha-3
    /// such as "USA") where the mode stays hidden.
    let familyModeHiddenStorefronts: [String]
    /// #242: the free rotating extra categories on Home. Off unless the server says on.
    let extraCategoriesEnabled: Bool

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
        case multiplayerEnabled = "multiplayer_enabled"
        case multiplayerEnabledAppStore = "multiplayer_enabled_app_store"
        case sharedQuizEnabled = "shared_quiz_enabled"
        case familyModeEnabled = "family_mode_enabled"
        case familyModeEnabledAppStore = "family_mode_enabled_app_store"
        case familyModeHiddenStorefronts = "family_mode_hidden_storefronts"
        case extraCategoriesEnabled = "extra_categories_enabled"
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
        maintenanceMessage: Notice? = nil,
        multiplayerEnabled: Bool = false,
        multiplayerEnabledAppStore: Bool = false,
        sharedQuizEnabled: Bool = false,
        familyModeEnabled: Bool = false,
        familyModeEnabledAppStore: Bool = false,
        familyModeHiddenStorefronts: [String] = [],
        extraCategoriesEnabled: Bool = false
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
        self.multiplayerEnabled = multiplayerEnabled
        self.multiplayerEnabledAppStore = multiplayerEnabledAppStore
        self.sharedQuizEnabled = sharedQuizEnabled
        self.familyModeEnabled = familyModeEnabled
        self.familyModeEnabledAppStore = familyModeEnabledAppStore
        self.familyModeHiddenStorefronts = familyModeHiddenStorefronts
        self.extraCategoriesEnabled = extraCategoriesEnabled
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
        multiplayerEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .multiplayerEnabled)) ?? false
        multiplayerEnabledAppStore = (try? container.decodeIfPresent(Bool.self, forKey: .multiplayerEnabledAppStore)) ?? false
        sharedQuizEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .sharedQuizEnabled)) ?? false
        familyModeEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .familyModeEnabled)) ?? false
        familyModeEnabledAppStore = (try? container.decodeIfPresent(Bool.self, forKey: .familyModeEnabledAppStore)) ?? false
        familyModeHiddenStorefronts = (try? container.decodeIfPresent([String].self, forKey: .familyModeHiddenStorefronts)) ?? []
        extraCategoriesEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .extraCategoriesEnabled)) ?? false
    }
}
