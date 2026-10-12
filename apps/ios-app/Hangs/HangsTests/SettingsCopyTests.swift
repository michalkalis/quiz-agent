//
//  SettingsCopyTests.swift
//  HangsTests
//
//  #200 — TF test of the redesign (2026-10-12), Settings copy.
//
//  Why these tests matter:
//  - Settings rows whose effect is not obvious from the title (voice commands,
//    voice hints, auto-confirm, recording sounds, read aloud) must say what they
//    do, in words a driver understands. A row that only repeats its title, names
//    a "listening bar" nobody sees, or promises "scores" while it mutes every
//    voice is the bug the founder found on the TestFlight build.
//  - The auto-confirm delay in the subtitle is the real countdown
//    (`Config.autoConfirmDelaySecs`); a hard-coded "5" would silently lie after
//    the next tuning.
//  - Custom packs sit right under the subscription: both are about what the
//    player can buy or create, and the founder wants them found before the
//    app-info rows.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("SettingsView — rows explain themselves (#200)")
struct SettingsCopyTests {
    /// Every `Text` of Settings in tree order, resolved in English.
    private func settingsTexts(viewModel: QuizViewModel = .preview) async throws -> [String] {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: viewModel)
            .environmentObject(appState)
            .environmentObject(NavigationModel())
        var texts: [String] = []
        try await ViewHosting.host(view) {
            texts = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        }
        return texts
    }

    @Test("voice rows say what they do instead of repeating the title or naming a listening bar")
    func voiceRowsExplainThemselves() async throws {
        let texts = try await settingsTexts()
        #expect(texts.contains("Control the quiz by voice, without tapping"))
        #expect(texts.contains("Show the voice commands you can say"))
        #expect(!texts.contains("Hands-free voice commands"), "the old subtitle only repeated the title")
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("listening bar") })
    }

    @Test("the recognizer row names what is ready: speech recognition, not 'Status'")
    func recognizerRowIsNamed() async throws {
        let texts = try await settingsTexts()
        #expect(texts.contains("Speech recognition"))
        #expect(!texts.contains("Status"))
    }

    @Test("the auto-confirm subtitle quotes the real countdown")
    func autoConfirmSubtitleUsesConfig() async throws {
        let texts = try await settingsTexts()
        let seconds = Config.autoConfirmDelaySecs
        #expect(texts.contains("Your answer is sent by itself after \(seconds) seconds unless you change it"))
    }

    @Test("recording sounds says the tone is the mic-on cue and the haptic stays")
    func recordingSoundsSubtitle() async throws {
        let texts = try await settingsTexts()
        #expect(texts.contains("A short tone when the microphone turns on. The vibration stays."))
    }

    @Test("the voice mute is called what it does: read aloud, covering questions, results and scores")
    func readAloudIsTheGlobalVoiceSwitch() async throws {
        let texts = try await settingsTexts()
        #expect(texts.contains("Read aloud"))
        #expect(texts.contains("Questions, results and scores"))
        #expect(!texts.contains("Speak scores aloud"))
    }

    @Test("reset history shows only the played count and explains what a reset does")
    func resetHistoryRow() async throws {
        let (vm, store) = Fixtures.makeViewModelWithPersistence()
        store.askedQuestionIds = ["q1", "q2", "q3"]
        let texts = try await settingsTexts(viewModel: vm)
        #expect(texts.contains("3"))
        #expect(!texts.contains { $0.contains("/ 500") }, "the cap is not part of the value")
        #expect(texts.contains("Played questions don't repeat. Resetting brings them back."))
    }

    @Test("custom packs follow the subscription group and come before the app-info rows")
    func packsSitNextToSubscription() async throws {
        let texts = try await settingsTexts()
        let subscription = try #require(texts.firstIndex(of: "subscription"))
        let packs = try #require(texts.firstIndex(of: "custom packs"))
        let about = try #require(texts.firstIndex(of: "about"))
        #expect(subscription < packs, "packs come after the subscription")
        #expect(packs < about, "packs come before the about rows")
    }
}
