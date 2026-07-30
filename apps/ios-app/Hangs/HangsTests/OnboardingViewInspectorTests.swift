//
//  OnboardingViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.13 — Onboarding redesign × 4 pages.
//
//  Why these tests matter:
//  - Each page must render its distinguishing headline and CTA so accidental
//    regressions (wrong page shown, missing button) fail fast.
//  - The denied branch must not grow a 4th dot — it sits on the permission dot,
//    which is a ViewModel-layer rule, not just a view detail.
//  - These are the invariants a refactor must not break.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - Helpers

@MainActor
private func makeVM(micGranted: Bool = true) -> OnboardingViewModel {
    let audio = MockAudioService()
    audio.micPermissionResult = micGranted
    let store = MockPersistenceStore()
    return OnboardingViewModel(audioService: audio, persistenceStore: store)
}

// MARK: - Page-indicator dot rule

@Suite("OnboardingView — page indicator")
struct OnboardingPageIndicatorTests {
    @Test("permissionDenied maps to pageIndex 2 (same dot as permission)")
    func deniedPageIndexIsTwo() async {
        let vm = makeVM(micGranted: false)
        vm.advance(); vm.advance() // welcome → features → permission
        await vm.requestMicPermission()
        #expect(vm.page == .permissionDenied)
        #expect(vm.pageIndex == 2, "Denied branch must sit on the 3rd dot, not a 4th")
    }
}

// MARK: - Structural: headlines and CTAs render per page

@MainActor
@Suite("OnboardingView — page structure")
struct OnboardingViewStructureTests {
    @Test("Welcome page renders 'ANSWER BY VOICE' headline and Continue CTA")
    func welcomePageRendersHeadlineAndCTA() async throws {
        let vm = makeVM()
        let view = OnboardingView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "ANSWER BY VOICE") }
            #expect(throws: Never.self) { try tree.find(text: "Continue") }
        }
    }

    @Test("Features page renders 'HANDS-FREE' headline and 4 feature titles")
    func featuresPageRendersCardRows() async throws {
        let vm = makeVM()
        vm.advance() // welcome → features
        let view = OnboardingView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "HANDS-FREE") }
            // #96 P2: the features card now teaches the command grammar (adopted
            // from pen `hTdkE`) — the founder's discoverability fix.
            #expect(throws: Never.self) { try tree.find(text: "Five simple words") }
            // #120: commands are English by DEFAULT (Slovak selectable in
            // Settings) — the "always" copy became wrong when Slovak shipped.
            #expect(throws: Never.self) { try tree.find(text: "English by default") }
            #expect(throws: Never.self) { try tree.find(text: "Buttons always work") }
        }
    }

    @Test("Permission page renders 'MIC ACCESS' headline and 'Allow Microphone' CTA")
    func permissionPageRendersHeadlineAndCTA() async throws {
        let vm = makeVM()
        vm.advance(); vm.advance() // welcome → features → permission
        let view = OnboardingView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "MIC ACCESS") }
            #expect(throws: Never.self) { try tree.find(text: "Allow Microphone") }
            #expect(throws: Never.self) { try tree.find(text: "Maybe later") }
        }
    }

    @Test("Denied page renders 'MIC IS OFF' headline, 'Open Settings' and 'Type answers instead'")
    func deniedPageRendersHeadlineAndBothCTAs() async throws {
        let vm = makeVM(micGranted: false)
        vm.advance(); vm.advance()
        await vm.requestMicPermission()
        let view = OnboardingView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "MIC IS OFF") }
            #expect(throws: Never.self) { try tree.find(text: "Open Settings") }
            #expect(throws: Never.self) { try tree.find(text: "Type answers instead") }
        }
    }
}
