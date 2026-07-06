//
//  SettingsNavigationTests.swift
//  HangsTests
//
//  #80 — Settings navigation HIG: pinned bar, leading back chip, large-title collapse.
//
//  Why these tests matter:
//  - The old Settings drew its back control top-RIGHT inside the scrollable
//    content — once scrolled, the screen had no visible navigation at all,
//    and hiding the bar killed the edge-swipe pop. These tests pin the fix:
//    the back control must live in the pinned toolbar (leading, per HIG) and
//    must NOT scroll away with content.
//  - VoiceOver must announce the control as "Back" (acceptance criterion) —
//    an icon-only chip without the label is invisible to VoiceOver users.
//  - The collapse threshold encodes Variant B (founder decision 1): the
//    pinned mono title may appear only after the hero headline scrolls away;
//    showing both at once would duplicate the title, never showing it would
//    leave the collapsed screen untitled.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("Settings navigation (#80)")
struct SettingsNavigationTests {

    // MARK: Back chip component

    @Test("HangsBackChip fires its action on tap")
    func backChipFiresAction() throws {
        var fired = false
        let chip = HangsBackChip { fired = true }
        try chip.inspect().find(ViewType.Button.self).tap()
        #expect(fired)
    }

    @Test("HangsBackChip is announced as 'Back' to VoiceOver")
    func backChipAccessibilityLabel() throws {
        let chip = HangsBackChip {}
        let label = try chip.inspect().find(ViewType.Button.self)
            .accessibilityLabel().string()
        #expect(label == "Back")
    }

    @Test("HangsBackChip shows the back arrow and the brand mark")
    func backChipContent() throws {
        let chip = HangsBackChip {}
        let icon = try chip.inspect().find(ViewType.Image.self).actualImage().name()
        #expect(icon == "arrow.left")
        #expect(throws: Never.self) {
            try chip.inspect().find(HangsBrandMark.self)
        }
    }

    // MARK: Large-title collapse threshold (Variant B)

    @Test("pinned title stays hidden while the hero is on screen")
    func heroNotCollapsedNearTop() {
        #expect(SettingsView.heroIsCollapsed(offsetY: 0) == false)
        #expect(SettingsView.heroIsCollapsed(offsetY: 40) == false)
    }

    @Test("pinned title appears once the hero has scrolled away")
    func heroCollapsedWhenScrolled() {
        #expect(SettingsView.heroIsCollapsed(offsetY: 200) == true)
    }

    // MARK: SettingsView integration

    @Test("back control lives in the pinned toolbar, not in scrollable content")
    func backControlIsPinned() async throws {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: .preview)
            .environmentObject(appState)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // The scrolling in-content chip (old pattern) must be gone — search
            // the scroll CONTENT only (the toolbar modifier hangs off the
            // ScrollView node itself, so searching from the ScrollView would
            // wrongly find the pinned chip).
            let scrollContent = try tree.find(ViewType.ScrollView.self)
                .find(ViewType.VStack.self)
            #expect(throws: (any Error).self) {
                try scrollContent.find(HangsBackChip.self)
            }
            // …and the chip must exist in the toolbar.
            let toolbar = try tree.find(ViewType.Toolbar.self)
            #expect(throws: Never.self) {
                try toolbar.find(HangsBackChip.self)
            }
        }
    }
}
