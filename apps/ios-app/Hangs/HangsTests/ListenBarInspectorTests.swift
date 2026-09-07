//
//  ListenBarInspectorTests.swift
//  HangsTests
//
//  #125 Track B — the shared `ListenBar` (replaces `ListeningPill`). One bar that
//  swaps text/accent by mode: teal command mode (COMMAND language, #120) vs pink
//  answer mode (app-locale). #122 Variant C feedback re-tints it without moving
//  it. Verifies: mode captions (incl. the Slovak command caption), that the bar
//  keeps its id + caption across every feedback phase, the #131 concrete-commands
//  sub-line (+ its corrective no-match variant), and that no mute lives here.
//  vzor: the retired CmdListenBarInspectorTests / ListeningPillInspectorTests.
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
        let view = ListenBar(mode: .command, language: .english)
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
        let view = ListenBar(mode: .command, language: .slovak)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "POČÚVAM PRÍKAZY")
            }
        }
    }

    // MARK: - Think countdown (#132 Track B, variant A)

    /// The MCQ think countdown lives IN the bar: the caption counts the window
    /// down and — the founder's correction to the mock — the concrete command
    /// words stay on the sub-line exactly as every other command bar shows them.
    @Test("Think countdown swaps the caption but keeps the command words")
    func thinkCountdownCaptionAndWords() async throws {
        let view = ListenBar(
            mode: .command,
            commandHint: #"Say "start" or "skip""#,
            thinkCountdown: .init(remaining: 32, total: 45)
        )
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "THINK — LISTENING IN 32 S")
            }
            let words = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(try words.text().string() == #"Say "start" or "skip""#)
        }
    }

    /// Answer mode must ignore a stray countdown — the mic is already live,
    /// there is nothing left to count down to.
    @Test("Answer mode ignores a think countdown")
    func answerModeIgnoresThinkCountdown() async throws {
        let view = ListenBar(mode: .answer(.mcq),
                             thinkCountdown: .init(remaining: 10, total: 45))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Listening — say A–D or the answer")
            }
            #expect(throws: (any Error).self) {
                _ = try tree.find(text: "THINK — LISTENING IN 10 S")
            }
        }
    }

    /// The think state keeps the bar's identity — same id, same full height —
    /// so the flip to answer mode at zero moves nothing on screen.
    @Test("Think state keeps the bar id and the full-with-words height")
    func thinkStateKeepsIdentityAndHeight() async throws {
        let view = ListenBar(
            mode: .command,
            commandHint: #"Say "start" or "skip""#,
            thinkCountdown: .init(remaining: 5, total: 45)
        )
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
        #expect(ListenBar.height(size: .full, hasSubLine: true) == 56)
    }

    // MARK: - Answer mode captions (app-locale, per kind)

    /// #171 Track I: the caption must offer BOTH ways in — a driver who does not
    /// know the option text is accepted falls back to letters and loses the
    /// hands-free win the tolerant matcher just bought.
    @Test("Answer/MCQ mode prompts for A–D or the answer text")
    func answerMCQCaption() async throws {
        let view = ListenBar(mode: .answer(.mcq))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Listening — say A–D or the answer")
            }
        }
    }

    @Test("Answer/true-false mode prompts for true or false")
    func answerTrueFalseCaption() async throws {
        let view = ListenBar(mode: .answer(.trueFalse))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "LISTENING — SAY TRUE OR FALSE")
            }
        }
    }

    @Test("Answer/open mode prompts for the spoken answer")
    func answerOpenCaption() async throws {
        let view = ListenBar(mode: .answer(.open))
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
            let view = ListenBar(mode: .answer(.mcq), feedback: phase)
            try await ViewHosting.host(view) {
                let tree = try view.inspect()
                #expect(throws: Never.self, "listen-bar id missing in \(phase)") {
                    try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
                }
                #expect(throws: Never.self, "caption missing in \(phase)") {
                    try tree.find(text: "Listening — say A–D or the answer")
                }
            }
        }
    }

    // MARK: - Concrete commands sub-line (#131 Track C)

    /// "LISTENING FOR COMMANDS" told a driver that the mic was open but never what
    /// to say — the founder read it as a dead-end (TF test 2026-07-29). The bar must
    /// name the actual words, and they must come from `VoiceCommandLexicon` so the
    /// screen's real grammar and the on-screen promise can never drift apart.
    @Test("Command mode names the screen's actual command words")
    func commandModeShowsConcreteCommands() async throws {
        let hint = VoiceCommandLexicon.hint(on: .question, language: .english)
        let view = ListenBar(mode: .command, commandHint: hint)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let sub = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(try sub.text().string() == hint)
            #expect(hint.contains("start") && hint.contains("skip"), "the question screen's words")
        }
    }

    /// The Slovak driver must read Slovak command words — the sub-line follows the
    /// COMMAND language (#120), not the app locale, exactly like the caption above it.
    @Test("Command sub-line follows the command language, not the app locale")
    func commandSubLineUsesCommandLanguage() async throws {
        let hint = VoiceCommandLexicon.hint(on: .question, language: .slovak)
        let view = ListenBar(mode: .command, commandHint: hint, language: .slovak)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let sub = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(try sub.text().string() == hint)
            #expect(hint.contains("štart"), "Slovak spoken form, not the English one")
        }
    }

    /// Amber alone said "something happened" and nothing else. A no-match must tell
    /// the driver what to do instead — while still naming the words, so the
    /// correction is actionable at a glance.
    @Test("No-match swaps the sub-line to a corrective hint that still names the words")
    func unmatchedShowsCorrectiveHint() async throws {
        let hint = VoiceCommandLexicon.hint(on: .question, language: .english)
        let view = ListenBar(mode: .command, feedback: .unmatched, commandHint: hint)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let sub = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            let rendered = try sub.text().string()
            #expect(rendered != hint, "the sub-line must change, not just the colour")
            #expect(rendered.contains(hint), "the corrective hint still names the commands")
        }
    }

    /// Answer mode's caption IS the instruction ("SAY A–D") — a sub-line there would
    /// be noise on the one screen where the driver is mid-answer.
    @Test("Answer mode renders no sub-line")
    func answerModeHasNoSubLine() async throws {
        let view = ListenBar(mode: .answer(.mcq), commandHint: "Say \"start\"")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            }
        }
    }

    // MARK: - Mute (moved back out — #131 Track C)

    /// #125 put a mute on the bar; it duplicated the question audio strip's (#85)
    /// and cost the driver the one fixed spot they had learned. The bar must carry
    /// none — `QuestionViewAudioStripTests` covers the strip being reachable in
    /// every state the bar shows.
    @Test("Bar carries no mute button")
    func barHasNoMuteButton() async throws {
        let view = ListenBar(mode: .answer(.mcq))
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                _ = try tree.find(viewWithAccessibilityIdentifier: "question.mute")
            }
        }
    }

    @Test("Accessibility identifier listen-bar is present")
    func accessibilityIdentifierPresent() async throws {
        let view = ListenBar(mode: .command)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
            }
        }
    }

    // MARK: - Size variant (#131 Track F, Option B) — migrated CmdListenBar coverage

    /// The founder picked "full + slim" over one uniform bar: Home gets ~40pt so
    /// the bar stops dominating a screen that has content, quiz screens keep the
    /// ~56pt bar where voice is the driver's only hand. Asserted on the pure
    /// mapping so a layout tweak can't silently re-inflate Home's bar.
    @Test("Slim is ~40pt, full stays ~56pt with the words / 44pt without")
    func sizeVariantHeights() {
        #expect(ListenBar.height(size: .slim, hasSubLine: true) == 40)
        #expect(ListenBar.height(size: .slim, hasSubLine: false) == 40)
        #expect(ListenBar.height(size: .full, hasSubLine: true) == 56)
        #expect(ListenBar.height(size: .full, hasSubLine: false) == 44)
    }

    /// A 40pt single row cannot carry "LISTENING FOR COMMANDS" AND the words to
    /// say — and the words are the part a driver acts on, so the caption is what
    /// shortens. Full keeps the whole sentence.
    @Test("Slim shortens the caption; full keeps the full sentence")
    func slimUsesShortCaption() async throws {
        let slim = ListenBar(mode: .command, commandHint: #"Say "start""#, size: .slim, language: .english)
        try await ViewHosting.host(slim) {
            let tree = try slim.inspect()
            #expect(throws: Never.self) { try tree.find(text: "LISTENING") }
            #expect(throws: (any Error).self) { try tree.find(text: "LISTENING FOR COMMANDS") }
        }

        let full = ListenBar(mode: .command, commandHint: #"Say "start""#, language: .english)
        try await ViewHosting.host(full) {
            let tree = try full.inspect()
            #expect(throws: Never.self) { try tree.find(text: "LISTENING FOR COMMANDS") }
        }
    }

    /// Shrinking the bar must not drop the one thing that tells the driver what
    /// to say — Home's slim bar still names its command, in the command language.
    @Test("Slim still names the screen's command words, in the command language")
    func slimKeepsTheWords() async throws {
        let hint = VoiceCommandLexicon.hint(on: .home, language: .slovak)
        let view = ListenBar(mode: .command, commandHint: hint, size: .slim, language: .slovak)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "POČÚVAM") }
            let sub = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
            #expect(try sub.text().string() == hint)
            #expect(hint.contains("štart"), "Slovak spoken form, not the English one")
        }
    }

    /// Migrated from the retired `CmdListenBar` (which Home used until #131
    /// Track F): the #122 lit / lit-miss tint is cosmetic, so the slim bar must
    /// keep its id and its words in every feedback phase — a driver who mis-spoke
    /// must still be able to read what to say.
    @Test("Slim bar keeps its id and its words across every feedback phase")
    func slimStructureStableAcrossPhases() async throws {
        let hint = VoiceCommandLexicon.hint(on: .home, language: .english)
        for phase in [VoiceFeedbackPhase.idle, .matched, .unmatched] {
            let view = ListenBar(mode: .command, feedback: phase, commandHint: hint, size: .slim)
            try await ViewHosting.host(view) {
                let tree = try view.inspect()
                #expect(throws: Never.self, "listen-bar id missing in \(phase)") {
                    try tree.find(viewWithAccessibilityIdentifier: "listen-bar")
                }
                let sub = try tree.find(viewWithAccessibilityIdentifier: "listen-bar.commands")
                #expect(try sub.text().string().contains(hint), "the words survive \(phase)")
            }
        }
    }
}
