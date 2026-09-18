//
//  SettingsViewCallModeTests.swift
//  HangsTests
//
//  #82 item 1 (decision 7, Variant B) — Call Mode toggle re-exposed in Settings.
//
//  Why these tests matter:
//  - The mic-picker footnote ("Switch to Call Mode in settings…") pointed at a
//    control that existed on no screen — AudioMode + toggleAudioMode() were
//    dead code. The structural test pins the Settings row so the footnote
//    stays true; if the row is removed again, this fails before a user hits
//    the dangling pointer.
//  - The wiring test locks toggleAudioMode()'s contract: it must flip the
//    persisted settings.audioMode between "call" and "media", because that is
//    what unlocks Bluetooth (HFP) microphones in the car — the app's core
//    driving use-case.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("SettingsView — Call Mode toggle (#82)")
struct SettingsViewCallModeTests {

    @Test("'Call Mode' toggle row renders in the view tree")
    func callModeRowRenders() async throws {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: .preview)
            .environmentObject(appState)
            .environmentObject(NavigationModel())
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Call Mode")
            }
        }
    }

    @Test("toggleAudioMode flips settings.audioMode media <-> call")
    func toggleFlipsPersistedMode() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.audioMode = "media"

        // toggleAudioMode() hops through an internal Task — no timer, so pumping
        // scheduler turns is enough (#180 track A: never a wall-clock bound).
        viewModel.toggleAudioMode()
        await pumpUntil({ viewModel.settings.audioMode == "call" }, "mode never flipped to call")
        #expect(viewModel.settings.audioMode == "call")

        viewModel.toggleAudioMode()
        await pumpUntil({ viewModel.settings.audioMode == "media" }, "mode never flipped back to media")
        #expect(viewModel.settings.audioMode == "media")
    }
}
