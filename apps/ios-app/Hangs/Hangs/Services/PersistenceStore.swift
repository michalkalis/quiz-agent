//
//  PersistenceStore.swift
//  Hangs
//
//  Unified UserDefaults persistence for session management and question history.
//

import Foundation
import os

/// Protocol for unified persistence (session + settings + question history).
/// @MainActor because all callers (QuizViewModel, AppState) are @MainActor.
@MainActor
protocol PersistenceStoreProtocol: Sendable {
    // MARK: - Device Identity

    /// Stable device identifier for usage tracking (persists across sessions)
    var deviceId: String { get }

    // MARK: - Onboarding

    /// Whether the user has completed the onboarding flow
    var hasCompletedOnboarding: Bool { get }

    /// Mark onboarding as completed
    func completeOnboarding()

    // MARK: - Session

    /// Get the currently stored session ID
    var currentSessionId: String? { get }

    /// Save a session ID for later resumption
    func saveSession(id: String)

    /// Clear the stored session ID
    func clearSession()

    // MARK: - Settings

    /// Save comprehensive quiz settings
    func saveSettings(_ settings: QuizSettings)

    /// Load saved quiz settings (returns default if not found)
    func loadSettings() -> QuizSettings

    // MARK: - Question History

    /// Library question IDs already served, oldest first. Packs keep their own
    /// ledger (`playedPackQuestionIds`) and never land here (#200).
    var askedQuestionIds: [String] { get }

    /// Remember a served library question. Keeps only the newest
    /// `PersistenceStore.historyWindow` ids: the oldest drop off silently,
    /// because no cap may ever block playing (#200).
    func addQuestionId(_ id: String)

    /// Clear all question history
    func clearHistory()

    /// Get list of question IDs for exclusion (alias for askedQuestionIds)
    /// - Returns: Array of question IDs to exclude
    func getExclusionList() -> [String]

    // MARK: - Pack progress (#200)

    /// The questions of custom pack `packId` already shown on this phone, in
    /// the order they were shown. Resetting the question history leaves them.
    func playedPackQuestionIds(packId: String) -> [String]

    /// Count one pack question as played. Called when it is on screen, never
    /// at prefetch, so a set left early does not burn the question it held back.
    func markPackQuestionPlayed(_ questionId: String, packId: String)

    /// Forget what was played of `packId`: the pack starts over from the top.
    func clearPackProgress(packId: String)

    // MARK: - Quiz Stats

    /// Load saved quiz statistics
    func loadStats() -> QuizStats

    /// Save quiz statistics
    func saveStats(_ stats: QuizStats)

    // MARK: - Contextual sign-in prompt (#58 §9)

    /// How many times the post-purchase sign-in sheet has been presented.
    /// Capped by SignInPromptGate (once at purchase + one reminder).
    var signInPromptShownCount: Int { get }

    /// Record one more presentation of the post-purchase sign-in sheet
    func incrementSignInPromptShownCount()
}

/// Unified UserDefaults-based persistence storage.
/// @MainActor ensures all UserDefaults access is on the main thread,
/// eliminating the need for nonisolated(unsafe) on the userDefaults property.
/// All callers (QuizViewModel, AppState) are @MainActor, so no async hop is needed.
@MainActor
final class PersistenceStore: PersistenceStoreProtocol {
    private let userDefaults: UserDefaults

    // Keys
    private let deviceIdKey = "device_id"
    private let onboardingKey = "has_completed_onboarding"
    private let sessionIdKey = "current_session_id"
    private let settingsKey = "quiz_settings"
    private let legacyMuteClearedKey = "mute_preference_cleared_173"
    private let difficultyDefaultMovedKey = "difficulty_default_random_216"
    private let historyKey = "asked_question_history"
    private let packProgressKey = "pack_played_question_ids"
    private let statsKey = "quiz_stats"
    private let signInPromptCountKey = "sign_in_prompt_shown_count"

    /// How many library question ids the history keeps (#200, founder
    /// 2026-10-12). Only an exclusion list: older ids may come back, which is
    /// fine, while a full list must never stop a quiz from starting.
    static let historyWindow = 5000

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Device Identity

    var deviceId: String {
        if let existing = userDefaults.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = "dev_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16))"
        userDefaults.set(newId, forKey: deviceIdKey)
        return newId
    }

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        userDefaults.bool(forKey: onboardingKey)
    }

    func completeOnboarding() {
        userDefaults.set(true, forKey: onboardingKey)
    }

    // MARK: - Session

    var currentSessionId: String? {
        userDefaults.string(forKey: sessionIdKey)
    }

    func saveSession(id: String) {
        userDefaults.set(id, forKey: sessionIdKey)

        Logger.persistence.debug("📦 PersistenceStore: Saved session ID: \(id, privacy: .public)")
    }

    func clearSession() {
        userDefaults.removeObject(forKey: sessionIdKey)

        Logger.persistence.debug("📦 PersistenceStore: Cleared session ID")
    }

    // MARK: - Settings

    func saveSettings(_ settings: QuizSettings) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: settingsKey)

            Logger.persistence.debug("📦 PersistenceStore: Saved settings: \(String(describing: settings), privacy: .public)")
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to encode settings: \(error, privacy: .public)")
        }
    }

    func loadSettings() -> QuizSettings {
        // #173: the one-time legacy-mute cleanup is spent on the FIRST load of
        // this build, whatever that load finds. A device with no (or an
        // unreadable) settings blob has nothing legacy to clean — but it must
        // still burn the marker here, or the user's first deliberate Settings
        // mute would be wiped as "legacy" on the next launch.
        let legacyMutePending = !userDefaults.bool(forKey: legacyMuteClearedKey)
        userDefaults.set(true, forKey: legacyMuteClearedKey)
        // #216: spent on the first load like the #173 marker, for the same reason.
        let difficultyMovePending = !userDefaults.bool(forKey: difficultyDefaultMovedKey)
        userDefaults.set(true, forKey: difficultyDefaultMovedKey)

        // Try to load saved settings
        guard let data = userDefaults.data(forKey: settingsKey) else {
            Logger.persistence.debug("📦 PersistenceStore: No saved settings found, using default")
            return QuizSettings.default
        }

        do {
            let decoder = JSONDecoder()
            let settings = try decoder.decode(QuizSettings.self, from: data)

            Logger.persistence.debug("📦 PersistenceStore: Loaded settings: \(String(describing: settings), privacy: .public)")

            let cleaned = legacyMutePending ? clearingLegacyMute(settings) : settings
            return difficultyMovePending ? movingOffOldDefaultDifficulty(cleaned) : cleaned
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to decode settings: \(error, privacy: .public), using default")
            return QuizSettings.default
        }
    }

    /// #216 (founder 2026-10-30): the default moved from Medium to Random. A
    /// saved Medium is almost always the old default written back by the
    /// auto-persist sink, and nothing on disk tells it apart from a deliberate
    /// pick, so it moves to the new default exactly once.
    private func movingOffOldDefaultDifficulty(_ settings: QuizSettings) -> QuizSettings {
        guard settings.difficulty == "medium" else { return settings }
        var moved = settings
        moved.difficulty = Config.defaultDifficulty
        return moved
    }

    /// One-time cleanup of a persisted mute that was never a preference (#173).
    /// Until this build the in-quiz mute button and the Settings "Sound" toggle
    /// wrote the SAME persisted flag, so a mute tapped mid-drive survived the
    /// app and silenced the first question of the next quiz (the founder's TF
    /// screenshot). The polluted value was already on disk and nothing could
    /// tell it apart from a deliberate Settings choice, so it is dropped exactly
    /// once, on the first load of a #173 build. #208 (founder 2026-10-16) makes
    /// the button write the persisted preference again on purpose: the marker
    /// is spent by then, so this never wipes such a mute.
    private func clearingLegacyMute(_ settings: QuizSettings) -> QuizSettings {
        guard settings.isMuted else { return settings }

        var cleaned = settings
        cleaned.isMuted = false
        saveSettings(cleaned)
        Logger.persistence.info("📦 PersistenceStore: dropped a legacy persisted mute (#173)")
        return cleaned
    }

    // MARK: - Question History

    var askedQuestionIds: [String] {
        userDefaults.stringArray(forKey: historyKey) ?? []
    }

    func addQuestionId(_ id: String) {
        var history = askedQuestionIds
        guard !history.contains(id) else { return }

        history.append(id)
        if history.count > Self.historyWindow {
            history.removeFirst(history.count - Self.historyWindow)
        }
        userDefaults.set(history, forKey: historyKey)

        Logger.persistence.debug("📦 PersistenceStore: Saved question \(id, privacy: .public) (total: \(history.count, privacy: .public))")
    }

    func clearHistory() {
        userDefaults.removeObject(forKey: historyKey)

        Logger.persistence.info("📦 PersistenceStore: Cleared all history")
    }

    func getExclusionList() -> [String] {
        let history = askedQuestionIds
        Logger.persistence.debug("📦 PersistenceStore: Retrieved \(history.count, privacy: .public) excluded question IDs")
        return history
    }

    // MARK: - Pack progress (#200)

    /// Every pack's played ids, keyed by pack id.
    private var packProgress: [String: [String]] {
        userDefaults.dictionary(forKey: packProgressKey) as? [String: [String]] ?? [:]
    }

    func playedPackQuestionIds(packId: String) -> [String] {
        packProgress[packId] ?? []
    }

    func markPackQuestionPlayed(_ questionId: String, packId: String) {
        var progress = packProgress
        var played = progress[packId] ?? []
        guard !played.contains(questionId) else { return }
        played.append(questionId)
        progress[packId] = played
        userDefaults.set(progress, forKey: packProgressKey)
    }

    func clearPackProgress(packId: String) {
        var progress = packProgress
        progress[packId] = nil
        userDefaults.set(progress, forKey: packProgressKey)

        Logger.persistence.info("📦 PersistenceStore: Cleared progress of pack \(packId, privacy: .public)")
    }

    // MARK: - Quiz Stats

    func loadStats() -> QuizStats {
        guard let data = userDefaults.data(forKey: statsKey) else {
            return QuizStats.empty
        }
        do {
            return try JSONDecoder().decode(QuizStats.self, from: data)
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to decode stats: \(error, privacy: .public), using empty")
            return QuizStats.empty
        }
    }

    func saveStats(_ stats: QuizStats) {
        do {
            let data = try JSONEncoder().encode(stats)
            userDefaults.set(data, forKey: statsKey)
        } catch {
            Logger.persistence.error("❌ PersistenceStore: Failed to encode stats: \(error, privacy: .public)")
        }
    }

    // MARK: - Contextual sign-in prompt (#58 §9)

    var signInPromptShownCount: Int {
        userDefaults.integer(forKey: signInPromptCountKey)
    }

    func incrementSignInPromptShownCount() {
        userDefaults.set(signInPromptShownCount + 1, forKey: signInPromptCountKey)
    }
}

