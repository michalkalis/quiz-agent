//
//  OnboardingViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.13, #237 — Microphone → Voice commands (+ the denied page).
//
//  Why these tests matter:
//  - Each page must render its distinguishing headline and CTA so accidental
//    regressions (wrong page shown, missing button) fail fast.
//  - Guideline 5.1.2(i): the AI services notice must sit on the page whose
//    buttons record the consent — since #237 the microphone page.
//  - The commands page must say that iOS will ask next, before the player taps.
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
    return OnboardingViewModel(audioService: audio, persistenceStore: store, enableCommands: {})
}

// MARK: - Structural: headlines and CTAs render per page

@MainActor
@Suite("OnboardingView — page structure")
struct OnboardingViewStructureTests {
    @Test("Microphone page renders its headline, both CTAs and the AI notice")
    func microphonePageRendersHeadlineCTAsAndNotice() async throws {
        let vm = makeVM()
        let view = OnboardingView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "MIC ACCESS") }
            #expect(throws: Never.self) { try tree.find(text: "Allow Microphone") }
            #expect(throws: Never.self) { try tree.find(text: "Maybe later") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "onboarding.aiDisclosure") }
            #expect(throws: Never.self) { try tree.find(button: "Privacy Policy") }
            // #237: the old welcome and features pages are gone.
            #expect(throws: (any Error).self) { try tree.find(text: "ANSWER BY VOICE") }
        }
    }

    @Test("Commands page renders its headline, the speech-recognition note and both CTAs")
    func commandsPageRendersHeadlineNoteAndCTAs() async throws {
        let vm = makeVM()
        await vm.requestMicPermission()
        let view = OnboardingView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "VOICE COMMANDS") }
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "onboarding.speechRecognitionNote") }
            #expect(throws: Never.self) { try tree.find(text: "Turn on commands") }
            #expect(throws: Never.self) { try tree.find(text: "Not now") }
            #expect(throws: Never.self) { try tree.find(text: "“next”") }
        }
    }

    @Test("Denied page renders 'MIC IS OFF' headline, 'Open Settings' and 'Type answers instead'")
    func deniedPageRendersHeadlineAndBothCTAs() async throws {
        let vm = makeVM(micGranted: false)
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
