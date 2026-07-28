//
//  ListenBarInspectorTests.swift
//  HangsTests
//
//  #125 Track B — the shared `ListenBar` (replaces `ListeningPill`). One bar that
//  swaps text/accent by mode: teal command mode (COMMAND language, #120) vs pink
//  answer mode (app-locale). #122 Variant C feedback re-tints it without moving
//  it. Verifies: mode captions (incl. the Slovak command caption), that the bar
//  keeps its id + caption across every feedback phase, and the mute button.
//  vzor: CmdListenBarInspectorTests / the old ListeningPillInspectorTests.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("ListenBar Inspector Tests")
@MainActor
struct ListenBarInspectorTests {
    // MARK: - Command mode caption (COMMAND language, #120)

    @Test("Command mode renders the English caption")
    func commandEnglishCaption() async throws {
        let view = ListenBar(mode: .command, isMuted: false, onToggleMute: {}, language: .english)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "LISTENING FOR COMMANDS")
            }
        }
    }

    /// The command caption follows the command-engine language, NOT the app
    /// locale — a Slovak driver must read the Slovak caption.
    @Test("Command mode renders the Slovak caption")
    func commandSlovakCaption() async throws {
        let view = ListenBar(mode: .command, isMuted: false, onToggleMute: {}, language: .slovak)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "POČÚVAM PRÍKAZY")
            }
        }
    }

    // MARK: - Answer mode captions (app-locale, per kind)

    @Test("Answer/MCQ mode prompts for A–D")
    func answerMCQCaption() async throws {
        let view = ListenBar(mode: .answer(.mcq), isMuted: false, onToggleMute: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "LISTENING — SAY A–D")
            }
        }
    }

    @Test("Answer/true-false mode prompts for true or false")
    func answerTrueFalseCaption() async throws {
        let view = ListenBar(mode: .answer(.trueFalse), isMuted: false, onToggleMute: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "LISTENING — SAY TRUE OR FALSE")
            }
        }
    }

    @Test("Answer/open mode prompts for the spoken answer")
    func answerOpenCaption() async throws {
        let view = ListenBar(mode: .answer(.open), isMuted: false, onToggleMute: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "LISTENING — SAY YOUR ANSWER")
            }
        }
    }

    // MARK: - Feedback tint structure stability (#122)

    /// The bar must keep its slot, id and caption in every feedback phase — the
    /// #122 tint is cosmetic only, never a layout/structure change.
    @Test("Bar keeps its id + caption across every feedback phase")
    func structureStableAcrossPhases() async throws {
        for phase in [VoiceFeedbackPhase.idle, .matched, .unmatched] {
            let view = ListenBar(mode: .answer(.mcq), feedback: phase, isMuted: false, onToggleMute: {})
            try await ViewHosting.host(view) {
                let tree = try view.inspect()
                #expect(throws: Never.self, "listen-bar id missing in \(phase)") {
                    try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
                }
                #expect(throws: Never.self, "caption missing in \(phase)") {
                    try tree.find(text: "LISTENING — SAY A–D")
                }
            }
        }
    }

    // MARK: - Mute button (absorbed from the audio strip)

    @Test("Bar carries the mute button")
    func muteButtonPresent() async throws {
        let view = ListenBar(mode: .answer(.mcq), isMuted: false, onToggleMute: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.mute")
            }
        }
    }

    @Test("Tapping mute fires the injected toggle")
    func muteButtonFiresToggle() async throws {
        var toggled = false
        let view = ListenBar(mode: .answer(.mcq), isMuted: false, onToggleMute: { toggled = true })
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let mute = try tree.find(viewWithAccessibilityIdentifier: "question.mute")
            try mute.button().tap()
            #expect(toggled == true)
        }
    }

    @Test("Accessibility identifier listen-bar is present")
    func accessibilityIdentifierPresent() async throws {
        let view = ListenBar(mode: .command, isMuted: false, onToggleMute: {})
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }
}
