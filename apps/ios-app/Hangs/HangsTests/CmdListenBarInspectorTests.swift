//
//  CmdListenBarInspectorTests.swift
//  HangsTests
//
//  Issue #122 Track A: the listening bar's caption must follow the COMMAND
//  language (#120 rule — it was hardcoded English and stayed English in Slovak
//  mode), and the transient feedback tint must re-skin the bar without touching
//  its structure (lit teal on a match, lit-miss amber on a miss — never red;
//  nothing failed). vzor: ListeningPillInspectorTests.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@Suite("CmdListenBar Inspector Tests")
@MainActor
struct CmdListenBarInspectorTests {
    // MARK: - Caption localization (why: Slovak mode must not claim English)

    @Test("Caption follows the command language")
    func captionFollowsCommandLanguage() {
        #expect(VoiceCommandLexicon.listeningCaption(language: .english) == "LISTENING FOR COMMANDS")
        #expect(VoiceCommandLexicon.listeningCaption(language: .slovak) == "POČÚVAM PRÍKAZY")
    }

    @Test("Bar renders the Slovak caption in Slovak command mode")
    func slovakCaptionRendered() throws {
        let bar = CmdListenBar(hint: #"Povedz „štart""#, language: .slovak)
        _ = try bar.inspect().find(text: "POČÚVAM PRÍKAZY")
    }

    @Test("Bar renders the English caption in English command mode")
    func englishCaptionRendered() throws {
        let bar = CmdListenBar(hint: #"Say "start""#, language: .english)
        _ = try bar.inspect().find(text: "LISTENING FOR COMMANDS")
    }

    // MARK: - Feedback tint (why: the bar is the app-wide #122C feedback surface)

    @Test("Hint text and a11y id survive every feedback phase")
    func structureStableAcrossPhases() throws {
        for phase in [VoiceFeedbackPhase.idle, .matched, .unmatched] {
            let bar = CmdListenBar(hint: #"Say "start""#, feedback: phase, language: .english)
            _ = try bar.inspect().find(text: #"Say "start""#)
            _ = try bar.inspect().find(viewWithAccessibilityIdentifier: "cmd-listen-bar")
        }
    }
}
