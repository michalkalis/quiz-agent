//
//  QuizViewModelSettingsCompatTests.swift
//  HangsTests
//
//  Task 3.4 (issue #31): covers two independent safety nets:
//
//  1. Exclusion-list wiring — `startNewQuiz` reads `persistenceStore.getExclusionList()`
//     and forwards the IDs to `networkService.startQuiz(excludedQuestionIds:)`.
//     Regression: any refactor that skips or replaces `getExclusionList()` would
//     silently repeat questions the user has already seen.
//     Code path: QuizViewModel.swift:373-402
//
//  2. `QuizSettings` backward-compat decoder — new fields added after v1 must
//     decode to their documented defaults from legacy persisted JSON (which will
//     not contain those keys). Removed legacy keys must be silently ignored.
//     Code path: QuizSettings.swift:120-136
//

import Foundation
import Testing
@testable import Hangs

// MARK: - Local helpers

/// Construct a `QuizViewModel` with a pre-seeded `MockPersistenceStore` and
/// a ready-to-go `MockNetworkService`. Returns all three so tests can assert
/// on captures after calling `startNewQuiz()`.
@MainActor
private func makeViewModelForExclusionTests(
    askedIds: [String] = []
) -> (QuizViewModel, MockNetworkService, MockPersistenceStore) {
    let mockNetwork = Fixtures.makeFullMockNetwork()
    let mockStore = MockPersistenceStore()
    mockStore.askedQuestionIds = askedIds
    let viewModel = QuizViewModel(
        networkService: mockNetwork,
        audioService: MockAudioService(),
        persistenceStore: mockStore
    )
    return (viewModel, mockNetwork, mockStore)
}

/// Decode a `QuizSettings` value from a plain dictionary.
/// Uses `JSONSerialization` so tests can express JSON as `[String: Any]` literals.
private func decodeSettings(_ json: [String: Any]) throws -> QuizSettings {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(QuizSettings.self, from: data)
}

// MARK: - Baseline JSON

/// Minimal v1-era persisted blob — only the keys that were always required.
/// Each decoder test starts from this and adds/removes one key.
private let legacyMinimalJSON: [String: Any] = [
    "language": "en",
    "audioMode": "media",
    "numberOfQuestions": 10,
    "difficulty": "medium",
    "autoAdvanceDelay": 8,
    "answerTimeLimit": 30,
    "autoRecordEnabled": true
]

// MARK: - Suite: Exclusion-list wiring

@Suite("QuizViewModel Exclusion-List Wiring")
@MainActor
struct QuizViewModelExclusionListTests {

    // MARK: - Test 1: Seeded history is forwarded

    /// Regression: a refactor that replaces `getExclusionList()` with an empty
    /// array literal would silently repeat seen questions every session restart.
    @Test("startNewQuiz forwards seeded history to startQuiz(excludedQuestionIds:)")
    func forwardsSeededHistory() async throws {
        let seeded = ["q_a", "q_b", "q_c"]
        let (viewModel, mockNetwork, _) = makeViewModelForExclusionTests(askedIds: seeded)

        await viewModel.startNewQuiz()

        #expect(mockNetwork.capturedStartQuizExcludedIds == seeded)
    }

    // MARK: - Test 2: Empty history produces empty array (not nil)

    /// Regression: `getExclusionList()` returns `[]` for a fresh install — the
    /// captured value must be `[]`, not `nil` (nil would indicate the capture
    /// property was never assigned, meaning `startQuiz` was never called).
    @Test("startNewQuiz passes empty array when question history is clean")
    func passesEmptyArrayForCleanHistory() async throws {
        let (viewModel, mockNetwork, _) = makeViewModelForExclusionTests(askedIds: [])

        await viewModel.startNewQuiz()

        #expect(mockNetwork.capturedStartQuizExcludedIds == [])
    }

    // MARK: - Test 3: Override params don't bypass exclusion list

    /// Regression: if `startNewQuiz(maxQuestions:difficulty:language:)` were
    /// refactored to use a different code path for override-param calls, the
    /// exclusion list might be skipped while override params are applied.
    @Test("startNewQuiz with override params still wires the exclusion list")
    func overrideParamsDoNotBypassExclusionList() async throws {
        let seeded = ["q_x", "q_y"]
        let (viewModel, mockNetwork, _) = makeViewModelForExclusionTests(askedIds: seeded)

        await viewModel.startNewQuiz(maxQuestions: 5, difficulty: "hard", language: "sk")

        #expect(mockNetwork.capturedStartQuizExcludedIds == seeded)
    }
}

// MARK: - Suite: QuizSettings backward-compat decoder

@Suite("QuizSettings Backward-Compat Decoder")
struct QuizSettingsBackwardCompatTests {

    // MARK: - Missing thinkingTime

    /// Regression: adding `thinkingTime` as a required `decode` call (instead of
    /// `decodeIfPresent ?? 10`) would throw a `DecodingError` for every v1-era
    /// blob and wipe the user's other settings on upgrade. The fallback tracks
    /// the product default (10 since #68 — driving-critical defaults).
    @Test("missing thinkingTime decodes with default value 10")
    func missingThinkingTimeDefaultsTen() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "thinkingTime")

        let settings = try decodeSettings(json)

        #expect(settings.thinkingTime == 10)
    }

    // MARK: - Missing autoConfirmEnabled

    /// Regression: same as above — must remain `decodeIfPresent ?? true` so
    /// legacy users don't get the confirm sheet silently disabled on upgrade.
    @Test("missing autoConfirmEnabled decodes with default value true")
    func missingAutoConfirmEnabledDefaultsTrue() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "autoConfirmEnabled")

        let settings = try decodeSettings(json)

        #expect(settings.autoConfirmEnabled == true)
    }

    // MARK: - Missing showConfirmSheet

    /// Regression: must remain `decodeIfPresent ?? true` so users who upgrade
    /// don't have the confirmation sheet unexpectedly hidden.
    @Test("missing showConfirmSheet decodes with default value true")
    func missingShowConfirmSheetDefaultsTrue() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "showConfirmSheet")

        let settings = try decodeSettings(json)

        #expect(settings.showConfirmSheet == true)
    }

    // MARK: - Missing isMuted

    /// Regression: must remain `decodeIfPresent ?? false` so TTS audio is not
    /// silently muted after upgrading from a build that predates the field.
    @Test("missing isMuted decodes with default value false")
    func missingIsMutedDefaultsFalse() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "isMuted")

        let settings = try decodeSettings(json)

        #expect(settings.isMuted == false)
    }

    // MARK: - Missing ageAppropriate

    /// Regression: must remain `decodeIfPresent` (no default) so the age filter
    /// is nil (= no filter) for users who upgrade from a build without the field.
    @Test("missing ageAppropriate decodes with default value nil")
    func missingAgeAppropriateDefaultsNil() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "ageAppropriate")

        let settings = try decodeSettings(json)

        #expect(settings.ageAppropriate == nil)
    }

    // MARK: - All five missing simultaneously (v1-era blob)

    /// Regression: a v1-era persisted blob that only contains the original
    /// required fields must decode successfully with all five new-field defaults.
    @Test("legacy v1-era blob (all five new fields missing) decodes with all defaults")
    func allFiveMissingSimultaneously() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "thinkingTime")
        json.removeValue(forKey: "autoConfirmEnabled")
        json.removeValue(forKey: "showConfirmSheet")
        json.removeValue(forKey: "isMuted")
        json.removeValue(forKey: "ageAppropriate")

        let settings = try decodeSettings(json)

        #expect(settings.thinkingTime == 10)
        #expect(settings.autoConfirmEnabled == true)
        #expect(settings.showConfirmSheet == true)
        #expect(settings.isMuted == false)
        #expect(settings.ageAppropriate == nil)
    }

    // MARK: - Missing #68 fields (recordingSoundsEnabled / includeImageQuestions)

    /// Regression: both #68 fields must stay `decodeIfPresent` with their
    /// product defaults — earcons ON (driving-safety feedback) and image
    /// questions OFF (unsuitable while driving) — for every pre-#68 blob.
    @Test("missing #68 fields decode with recording sounds on and image questions off")
    func missingIssue68FieldsUseProductDefaults() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "recordingSoundsEnabled")
        json.removeValue(forKey: "includeImageQuestions")

        let settings = try decodeSettings(json)

        #expect(settings.recordingSoundsEnabled == true)
        #expect(settings.includeImageQuestions == false)
    }

    // MARK: - Driving-critical default (#68)

    /// #68 acceptance: the default thinking time must stay short — a driver
    /// can't wait a minute for auto-record to arm. Guards against the default
    /// creeping back up without a founder decision.
    @Test("default thinkingTime is 10 and stays under 30")
    func defaultThinkingTimeIsDrivingShort() {
        #expect(QuizSettings.default.thinkingTime == 10)
        #expect(QuizSettings.default.thinkingTime < 30)
        #expect(QuizSettings.thinkingTimeOptions.contains(10))
    }

    // MARK: - Unknown legacy keys are silently ignored

    /// Regression: if `Codable` synthesis ever replaced the custom `init(from:)`
    /// with a strict decoder, `voiceCommandsEnabled` / `bargeInEnabled` (removed
    /// keys from an older build) would throw a `DecodingError`.  The custom
    /// decoder relies on Codable's automatic unknown-key dropping; this test
    /// proves that behaviour is preserved.
    @Test("removed legacy keys voiceCommandsEnabled and bargeInEnabled are silently ignored")
    func legacyKeysAreIgnored() throws {
        var json = legacyMinimalJSON
        json["voiceCommandsEnabled"] = true
        json["bargeInEnabled"] = false

        #expect(throws: Never.self) {
            _ = try decodeSettings(json)
        }
    }

    // MARK: - Missing required key still throws

    /// Positive control: backward-compat is targeted at *optional* new fields —
    /// a blob with a genuinely required field absent must still throw.
    @Test("missing required key language throws DecodingError")
    func missingRequiredKeyThrows() throws {
        var json = legacyMinimalJSON
        json.removeValue(forKey: "language")

        #expect(throws: DecodingError.self) {
            _ = try decodeSettings(json)
        }
    }
}
