//
//  SettingsNavigationTests.swift
//  HangsTests
//
//  Settings navigation. Founder batch 2026-07-12 replaced #80's brand back
//  chip + custom edge-pan recognizer with the untouched SYSTEM back button and
//  native swipe-to-pop — custom navigation gestures proved fragile across iOS
//  versions (the iOS 26 interactivePopGestureRecognizer delegate breakage that
//  forced #80's pan hack is exactly the failure mode we're opting out of).
//
//  Why these tests matter:
//  - SettingsView must never hide the system back button again: hiding it is
//    what killed the native edge-swipe and forced the custom-gesture detour.
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
@Suite("Settings navigation")
struct SettingsNavigationTests {

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

    // MARK: Native back (founder batch 2026-07-12)

    @Test("SettingsView keeps the system back button — no custom back control")
    func systemBackButtonNotHidden() async throws {
        let appState = AppState(
            networkService: MockNetworkService(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore()
        )
        let view = SettingsView(viewModel: .preview)
            .environmentObject(appState)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            // The old custom control carried this identifier; native back means
            // no view in the tree claims it anymore.
            #expect(throws: (any Error).self) {
                try tree.find(viewWithAccessibilityIdentifier: "settings-back-button")
            }
            // navigationBarBackButtonHidden must not be re-applied: ViewInspector
            // surfaces it as a flag on the ScrollView node when present.
            let scroll = try tree.find(ViewType.ScrollView.self)
            #expect(throws: (any Error).self) {
                _ = try scroll.navigationBarBackButtonHidden()
            }
        }
    }
}
