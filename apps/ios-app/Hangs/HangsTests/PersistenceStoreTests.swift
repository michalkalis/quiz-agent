//
//  PersistenceStoreTests.swift
//  HangsTests
//
//  Unit tests for PersistenceStore using isolated UserDefaults.
//

import Foundation
@testable import Hangs
import Testing

// MARK: - IsolatedDefaults

/// Holds a unique UserDefaults suite for the duration of one test.
/// `deinit` removes the suite — Swift Testing creates a fresh struct per
/// test, so the helper goes out of scope when the test returns.
final nonisolated class IsolatedDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = "test.PersistenceStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func makeStore() -> PersistenceStore {
        PersistenceStore(userDefaults: defaults)
    }
}

// MARK: - Session Tests

@Suite("PersistenceStore Session Tests")
@MainActor
struct PersistenceStoreSessionTests {
    /// Creates a PersistenceStore backed by a unique, auto-cleaned UserDefaults suite.
    private func makeStore() -> (PersistenceStore, IsolatedDefaults) {
        let isolated = IsolatedDefaults()
        return (isolated.makeStore(), isolated)
    }

    // MARK: - Session ID Round-Trip

    @Test("saveSession stores and currentSessionId retrieves the ID")
    func saveAndRetrieveSessionId() {
        let (store, isolated) = makeStore()
        _ = isolated

        store.saveSession(id: "session_abc")

        #expect(store.currentSessionId == "session_abc")
    }

    @Test("clearSession removes the stored session ID")
    func clearSessionRemovesId() {
        let (store, isolated) = makeStore()
        _ = isolated

        store.saveSession(id: "session_abc")
        store.clearSession()

        #expect(store.currentSessionId == nil)
    }

    @Test("currentSessionId is nil when no session has been saved")
    func currentSessionIdNilByDefault() {
        let (store, isolated) = makeStore()
        _ = isolated

        #expect(store.currentSessionId == nil)
    }

    // MARK: - Settings Round-Trip

    @Test("saveSettings and loadSettings round-trip correctly")
    func settingsRoundTrip() {
        let (store, isolated) = makeStore()
        _ = isolated

        let settings = QuizSettings(
            language: "sk",
            audioMode: "media",
            numberOfQuestions: 20,
            categories: ["science-nature"],
            difficulty: "hard",
            autoAdvanceDelay: 5,
            preferredInputDeviceId: "device_123"
        )

        store.saveSettings(settings)
        let loaded = store.loadSettings()

        #expect(loaded == settings)
    }

    @Test("loadSettings returns .default when no saved data exists")
    func loadSettingsReturnsDefaultWhenEmpty() {
        let (store, isolated) = makeStore()
        _ = isolated

        let loaded = store.loadSettings()

        #expect(loaded == QuizSettings.default)
    }

    @Test("loadSettings returns .default when saved data is corrupt JSON")
    func loadSettingsReturnsDefaultOnCorruptData() {
        let (store, isolated) = makeStore()

        // Write invalid JSON data to the settings key
        let corruptData = Data("not valid json".utf8)
        isolated.defaults.set(corruptData, forKey: "quiz_settings")

        let loaded = store.loadSettings()

        #expect(loaded == QuizSettings.default)
    }

    // MARK: - #173: legacy persisted mute

    /// The in-quiz mute button used to write the SAME persisted flag as the
    /// Settings "Sound" toggle, so a mute tapped mid-drive silenced the first
    /// question of the NEXT launch (founder TF screenshot 2026-09-06). Nothing
    /// on disk can tell that value apart from a deliberate Settings choice, so
    /// the upgrade drops it exactly once — otherwise the very device that
    /// reported the bug still starts its next quiz in silence.
    @Test("loadSettings drops a mute persisted by the pre-#173 in-quiz button, once")
    func loadSettingsDropsLegacyMuteOnce() {
        let (store, isolated) = makeStore()
        _ = isolated

        var muted = QuizSettings.default
        muted.isMuted = true
        store.saveSettings(muted)

        #expect(store.loadSettings().isMuted == false, "the legacy mute must not survive the upgrade")

        // A mute chosen AFTER the cleanup is a real preference and must stick.
        store.saveSettings(muted)
        #expect(store.loadSettings().isMuted == true, "the cleanup is one-time, not a mute ban")
    }

    /// A fresh install has no legacy mute to clean, and the real launch order is
    /// load-then-save (QuizViewModel loads in `init`, the auto-persist sink only
    /// fires on a later change). If the first load doesn't spend the one-time
    /// marker, the user's FIRST deliberate Settings mute is wiped as "legacy" on
    /// the next launch — destroying a choice on a device that never had the bug.
    @Test("a mute chosen on a fresh install survives the next launch")
    func freshInstallMuteSurvivesRelaunch() {
        let (store, isolated) = makeStore()
        _ = isolated

        _ = store.loadSettings() // launch 1: nothing persisted yet

        var muted = QuizSettings.default
        muted.isMuted = true
        store.saveSettings(muted) // the user turns Sound off in Settings

        #expect(store.loadSettings().isMuted == true, "a real preference must survive launch 2")
    }

    /// Same hole via the corrupt-blob path: it also returns before any cleanup,
    /// so the marker has to be spent on that exit too.
    @Test("a mute chosen after an unreadable settings blob survives the next launch")
    func muteAfterCorruptBlobSurvivesRelaunch() {
        let (store, isolated) = makeStore()

        isolated.defaults.set(Data("not valid json".utf8), forKey: "quiz_settings")
        _ = store.loadSettings()

        var muted = QuizSettings.default
        muted.isMuted = true
        store.saveSettings(muted)

        #expect(store.loadSettings().isMuted == true)
    }

    // MARK: - #216: default difficulty moved from Medium to Random

    /// The founder's TestFlight phone still started on Medium after the default
    /// changed: the old default was saved back to disk and reads like a pick.
    /// A fresh install must start mixed without any saved blob.
    @Test("a fresh install starts on the mixed difficulty")
    func freshInstallStartsRandom() {
        let (store, isolated) = makeStore()
        _ = isolated

        #expect(store.loadSettings().difficulty == "random")
    }

    @Test("a saved Medium moves to Random once; a later Medium pick sticks")
    func savedMediumMovesOnce() {
        let (store, isolated) = makeStore()
        _ = isolated

        var medium = QuizSettings.default
        medium.difficulty = "medium"
        store.saveSettings(medium)

        #expect(store.loadSettings().difficulty == "random", "the old default must not survive the update")

        store.saveSettings(medium)
        #expect(store.loadSettings().difficulty == "medium", "Medium picked after the update is a real choice")
    }

    /// The launch reads settings twice: AppState for the speech recognizer's
    /// language, then the quiz view model. The first read spent the one-time
    /// marker and threw the moved value away, so the phone kept Medium after
    /// the update that was meant to move it.
    @Test("the move to Random survives the launch's second read of the settings")
    func moveSurvivesASecondRead() {
        let (store, isolated) = makeStore()
        _ = isolated

        var medium = QuizSettings.default
        medium.difficulty = "medium"
        store.saveSettings(medium)

        _ = store.loadSettings() // AppState: the recognizer's language
        #expect(store.loadSettings().difficulty == "random", "QuizViewModel's read got the old Medium back")
    }

    @Test("a saved Hard or Easy is a real choice and is never moved")
    func otherDifficultiesStay() {
        let (store, isolated) = makeStore()
        _ = isolated

        var hard = QuizSettings.default
        hard.difficulty = "hard"
        store.saveSettings(hard)

        #expect(store.loadSettings().difficulty == "hard")
    }

    // MARK: - Legacy Keys Ignored

    @Test("loadSettings ignores stale legacy individual keys")
    func loadSettingsIgnoresLegacyKeys() {
        let (store, isolated) = makeStore()

        // Legacy keys that existed before the unified QuizSettings JSON.
        // After migration code removal, these should be ignored.
        isolated.defaults.set("sk", forKey: "preferred_language")
        isolated.defaults.set("media", forKey: "preferred_audio_mode")

        let loaded = store.loadSettings()

        // No migration — should return .default regardless of legacy keys
        #expect(loaded == QuizSettings.default)
    }
}

// MARK: - Question History Tests

@Suite("PersistenceStore Question History Tests")
@MainActor
struct PersistenceStoreQuestionHistoryTests {
    /// Creates a PersistenceStore backed by a unique, auto-cleaned UserDefaults suite.
    private func makeStore() -> (PersistenceStore, IsolatedDefaults) {
        let isolated = IsolatedDefaults()
        return (isolated.makeStore(), isolated)
    }

    // MARK: - Basic Operations

    @Test("addQuestionId persists and retrieves the ID")
    func addAndRetrieve() throws {
        let (store, isolated) = makeStore()
        _ = isolated

        store.addQuestionId("q_001")

        #expect(store.askedQuestionIds == ["q_001"])
    }

    @Test("adding same ID twice does not create duplicates")
    func deduplication() throws {
        let (store, isolated) = makeStore()
        _ = isolated

        store.addQuestionId("q_001")
        store.addQuestionId("q_001")

        #expect(store.askedQuestionIds == ["q_001"])
    }

    @Test("clearHistory removes all entries")
    func clearHistory() throws {
        let (store, isolated) = makeStore()
        _ = isolated

        store.addQuestionId("q_001")
        store.addQuestionId("q_002")
        store.clearHistory()

        #expect(store.askedQuestionIds.isEmpty)
    }

    @Test("getExclusionList returns same as askedQuestionIds")
    func exclusionListMatchesAskedIds() throws {
        let (store, isolated) = makeStore()
        _ = isolated

        store.addQuestionId("q_001")
        store.addQuestionId("q_002")

        #expect(store.getExclusionList() == store.askedQuestionIds)
    }

    @Test("empty history returns empty array")
    func emptyHistoryReturnsEmptyArray() {
        let (store, isolated) = makeStore()
        _ = isolated

        #expect(store.askedQuestionIds == [])
        #expect(store.getExclusionList() == [])
    }

    // MARK: - Window (#200)

    /// WHY (#200, founder 2026-10-12): at 500 ids the old cap refused every
    /// quiz start. The history is only an exclusion list, so past the window
    /// the oldest ids drop off silently and a new question is always taken.
    @Test("past the window the oldest ids drop off and the newest is kept")
    func windowDropsOldest() {
        let (store, isolated) = makeStore()
        let window = PersistenceStore.historyWindow
        // A full history as an earlier build left it on disk.
        isolated.defaults.set((0 ..< window).map { "q_\($0)" }, forKey: "asked_question_history")
        #expect(store.askedQuestionIds.count == window)

        store.addQuestionId("q_new")

        #expect(store.askedQuestionIds.count == window, "the history must stay at the window")
        #expect(store.askedQuestionIds.first == "q_1", "the oldest id drops off first")
        #expect(store.askedQuestionIds.last == "q_new", "a new question is never refused")
    }
}

// MARK: - Pack progress (#200)

@Suite("PersistenceStore pack progress")
@MainActor
struct PersistenceStorePackProgressTests {
    private func makeStore() -> (PersistenceStore, IsolatedDefaults) {
        let isolated = IsolatedDefaults()
        return (isolated.makeStore(), isolated)
    }

    /// WHY: each pack continues where this phone left it, so its ledger must
    /// survive the app (a fresh store over the same defaults), stay per pack,
    /// and count a question once however often it is shown.
    @Test("a pack's played questions persist per pack, without duplicates")
    func ledgerPersistsPerPack() {
        let isolated = IsolatedDefaults()
        let store = isolated.makeStore()

        store.markPackQuestionPlayed("p1_q1", packId: "pack-1")
        store.markPackQuestionPlayed("p1_q2", packId: "pack-1")
        store.markPackQuestionPlayed("p1_q1", packId: "pack-1")
        store.markPackQuestionPlayed("p2_q1", packId: "pack-2")

        let relaunched = isolated.makeStore()
        #expect(relaunched.playedPackQuestionIds(packId: "pack-1") == ["p1_q1", "p1_q2"])
        #expect(relaunched.playedPackQuestionIds(packId: "pack-2") == ["p2_q1"])
        #expect(relaunched.playedPackQuestionIds(packId: "pack-3").isEmpty)
    }

    /// WHY (founder 2026-10-12): resetting the question history must not
    /// rewind a pack, and starting one pack over must not touch another.
    @Test("history reset keeps pack progress; clearing one pack keeps the others")
    func resetsAreIndependent() {
        let (store, isolated) = makeStore()
        _ = isolated
        store.addQuestionId("lib_q1")
        store.markPackQuestionPlayed("p1_q1", packId: "pack-1")
        store.markPackQuestionPlayed("p2_q1", packId: "pack-2")

        store.clearHistory()
        #expect(store.askedQuestionIds.isEmpty)
        #expect(store.playedPackQuestionIds(packId: "pack-1") == ["p1_q1"])

        store.clearPackProgress(packId: "pack-1")
        #expect(store.playedPackQuestionIds(packId: "pack-1").isEmpty)
        #expect(store.playedPackQuestionIds(packId: "pack-2") == ["p2_q1"])
    }
}
