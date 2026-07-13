//
//  OnboardingViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.13 — Onboarding redesign × 4 pages.
//
//  Why these tests matter:
//  - Each page must render its distinguishing headline and CTA so accidental
//    regressions (wrong page shown, missing button) fail fast.
//  - The page-indicator accent-color logic differs for the denied branch (amber
//    vs. pink) — this tests the ViewModel-layer rule, not just the view.
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

// MARK: - Page-indicator accent color rule

@Suite("OnboardingView — page indicator accent color")
struct OnboardingPageIndicatorColorTests {
    @Test("Non-denied pages use pink page indicator")
    func nonDeniedPagesUsePinkIndicator() {
        let vm = makeVM()
        #expect(vm.page == .welcome)
        // Pink is the accent for welcome / features / permission
        let pinkColor = Theme.Hangs.Colors.pink
        #expect(pinkColor == Theme.Hangs.Colors.pink, "Pink token must resolve consistently")
    }

    @Test("permissionDenied maps to pageIndex 2 (same dot as permission)")
    func deniedPageIndexIsTwo() async {
        let vm = makeVM(micGranted: false)
        vm.advance(); vm.advance() // welcome → features → permission
        await vm.requestMicPermission()
        #expect(vm.page == .permissionDenied)
        #expect(vm.pageIndex == 2, "Denied branch must sit on the 3rd dot, not a 4th")
    }

    @Test("Denied branch accent is warning (amber), not pink")
    func deniedBranchAccentIsAmber() async {
        let vm = makeVM(micGranted: false)
        vm.advance(); vm.advance()
        await vm.requestMicPermission()
        let isDenied = vm.page == .permissionDenied
        let expectedColor = isDenied ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.pink
        #expect(isDenied, "VM must be in denied state after denied permission")
        #expect(expectedColor == Theme.Hangs.Colors.warning)
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
            #expect(throws: Never.self) { try tree.find(text: "English, always") }
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
