//
//  AIProcessingConsent.swift
//  Hangs
//
//  #209 (App Review guideline 5.1.2(i)): before first use the player is told,
//  on the first onboarding page, that spoken answers and typed pack topics go
//  to third-party AI services, and continuing past that page is the consent.
//  This records when that happened and which disclosure text was shown, so a
//  changed provider list can be shown again under a new version.
//

import Foundation

nonisolated enum AIProcessingConsent {
    static let consentedAtKey = "aiProcessingConsent.consentedAt"
    static let versionKey = "aiProcessingConsent.version"
    /// Bump when the disclosed provider list changes.
    static let currentVersion = 1

    static func record(at date: Date = .now, defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: consentedAtKey)
        defaults.set(currentVersion, forKey: versionKey)
    }

    static func hasConsented(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: consentedAtKey) != nil
            && defaults.integer(forKey: versionKey) >= currentVersion
    }
}
