//
//  FamilyMode.swift
//  Hangs
//
//  #236 — family mode „S deťmi“ (plan docs/issues/issue-236-family-mode-build.md,
//  increment A1): the age bands, the server's topics per band, what the app
//  remembers of the mode, and the round a start asks for.
//

import Foundation

/// A child age band: a content setting of the round, never a property of the
/// player (#236 guardrail 1). Raw values are the server's `AGE_BANDS`.
nonisolated enum FamilyBand: String, Codable, CaseIterable, Sendable {
    case kids4to6 = "kids_4_6"
    case kids7to9 = "kids_7_9"
    case kids10to12 = "kids_10_12"

    /// "4–6": a number range, the same in every language.
    var label: String {
        switch self {
        case .kids4to6: "4–6"
        case .kids7to9: "7–9"
        case .kids10to12: "10–12"
        }
    }

    /// What VoiceOver reads instead of the dash ("4 až 6 rokov").
    var spokenLabel: LocalizedStringResource {
        switch self {
        case .kids4to6: LocalizedStringResource("Ages 4 to 6", comment: "#236 family mode: VoiceOver name of the 4–6 age band")
        case .kids7to9: LocalizedStringResource("Ages 7 to 9", comment: "#236 family mode: VoiceOver name of the 7–9 age band")
        case .kids10to12: LocalizedStringResource("Ages 10 to 12", comment: "#236 family mode: VoiceOver name of the 10–12 age band")
        }
    }

    /// One line under the band in the age sheet (canvas F1).
    var summary: LocalizedStringResource {
        switch self {
        case .kids4to6: LocalizedStringResource("Yes, no or one of two", comment: "#236 family mode age sheet: what 4–6 questions look like")
        case .kids7to9: LocalizedStringResource("Short questions, answer by voice", comment: "#236 family mode age sheet: what 7–9 questions look like")
        case .kids10to12: LocalizedStringResource("Longer questions, answer by voice", comment: "#236 family mode age sheet: what 10–12 questions look like")
        }
    }
}

/// One topic of a band (`GET /api/v1/family/topics`, backend `FamilyTopic`).
nonisolated struct FamilyTopic: Codable, Equatable, Sendable, Identifiable {
    /// The `family-*` category key the round is started with.
    let key: String
    /// Already in the asked language.
    let name: String
    /// Questions in one round: 6 for 4–6, 10 for the older bands.
    let roundSize: Int

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key
        case name
        case roundSize = "round_size"
    }
}

/// `GET /api/v1/family/topics?language=` (backend `FamilyTopicsResponse`).
/// `band` is plain text on purpose: a band this build does not know is
/// dropped by `topicsByBand`, never a decoding failure.
nonisolated struct FamilyTopicsResponse: Codable, Equatable, Sendable {
    struct Band: Codable, Equatable, Sendable {
        let band: String
        let topics: [FamilyTopic]
    }

    let bands: [Band]

    /// The known bands with at least one topic.
    var topicsByBand: [FamilyBand: [FamilyTopic]] {
        var result: [FamilyBand: [FamilyTopic]] = [:]
        for entry in bands {
            guard let band = FamilyBand(rawValue: entry.band), !entry.topics.isEmpty else { continue }
            result[band] = entry.topics
        }
        return result
    }
}

/// What the app remembers of the mode (founder 2026-11-18: also across
/// launches), under its own key so a decoding error never touches the solo
/// settings. `band == nil` = never chosen: the first flip asks for it.
nonisolated struct FamilySettings: Codable, Equatable, Sendable {
    var isOn = false
    var band: FamilyBand?
    /// The last topic per band (band raw value → topic key).
    var topicByBand: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case isOn = "is_on"
        case band
        case topicByBand = "topic_by_band"
    }

    init(isOn: Bool = false, band: FamilyBand? = nil, topicByBand: [String: String] = [:]) {
        self.isOn = isOn
        self.band = band
        self.topicByBand = topicByBand
    }

    /// Every field on its own: a band a later build removed drops only the band.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = (try? container.decodeIfPresent(Bool.self, forKey: .isOn)) ?? false
        band = try? container.decodeIfPresent(FamilyBand.self, forKey: .band)
        topicByBand = (try? container.decodeIfPresent([String: String].self, forKey: .topicByBand)) ?? [:]
    }
}

/// The round a family start asks the server for: one topic of one band.
nonisolated struct FamilyRound: Equatable, Sendable {
    let band: FamilyBand
    let topic: String
    let roundSize: Int
}
