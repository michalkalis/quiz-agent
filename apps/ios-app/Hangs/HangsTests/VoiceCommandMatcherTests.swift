//
//  VoiceCommandMatcherTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.3. These tests pin WHY each
//  matching rule matters for a Slovak-accented driver on a native-English
//  recognizer with NO vocabulary biasing:
//   • routing must be SCREEN-SCOPED (a command inert on the wrong screen must
//     not fire an action that screen doesn't own),
//   • an accented near-miss ("stat") must still route to `start`,
//   • noise must resolve to nil (never guess a wrong action),
//   • `skip` is STRICT whole-utterance because skipping burns a question, so a
//     sentence that merely CONTAINS "skip" must be rejected,
//   • the undo window must abort in time and commit once elapsed.
//

import Foundation
@testable import Hangs
import Testing

@Suite("VoiceCommandMatcher")
struct VoiceCommandMatcherTests {

    // MARK: - Screen-scoped routing

    @Test("Each command routes on the screen that owns it")
    func routesPerScreen() {
        #expect(VoiceCommandMatcher.match(transcript: "start", on: .home) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "start", on: .question) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "next", on: .result) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "again", on: .confirmation) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "repeat", on: .question) == .repeatQuestion)
    }

    @Test("A command inert on a screen resolves to nil (scoping)")
    func inertOffScreen() {
        // "next" belongs to the result, not the question screen.
        #expect(VoiceCommandMatcher.match(transcript: "next", on: .question) == nil)
        // "start" belongs to home/question, not the confirmation sheet.
        #expect(VoiceCommandMatcher.match(transcript: "start", on: .confirmation) == nil)
        // "skip" belongs to the question screen, not the result.
        #expect(VoiceCommandMatcher.match(transcript: "skip", on: .result) == nil)
    }

    @Test("'ok' is confirm on the sheet and advance on the result (same command, screen-scoped)")
    func okScopedToBothConfirmationAndResult() {
        // Both screens accept "ok"; the differing ACTION is the caller's job.
        #expect(VoiceCommandMatcher.match(transcript: "ok", on: .confirmation) == .ok)
        #expect(VoiceCommandMatcher.match(transcript: "okay", on: .result) == .ok)
        // But "ok" is inert on the question screen (not in its command set).
        #expect(VoiceCommandMatcher.match(transcript: "ok", on: .question) == nil)
    }

    // MARK: - Accent tolerance

    @Test("Accented near-miss 'stat' still routes to start")
    func accentedNearMiss() {
        #expect(VoiceCommandMatcher.match(transcript: "stat", on: .question) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "Staat.", on: .home) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "nekst", on: .result) == .next)
    }

    @Test("Case and diacritics are folded")
    func caseAndDiacriticsFolded() {
        #expect(VoiceCommandMatcher.match(transcript: "  START ", on: .home) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "Ňext!", on: .result) == .next)
    }

    @Test("Filler words around a command are tolerated")
    func fillerTolerated() {
        #expect(VoiceCommandMatcher.match(transcript: "um start please", on: .question) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "ok please", on: .confirmation) == .ok)
    }

    // MARK: - Non-command rejection

    @Test("Noise / non-command resolves to nil")
    func noiseRejected() {
        #expect(VoiceCommandMatcher.match(transcript: "hello there", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "the weather is nice", on: .result) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "", on: .home) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "...", on: .home) == nil)
    }

    // MARK: - Strict skip

    @Test("Bare 'skip' (± filler) is a skip")
    func bareSkipMatches() {
        #expect(VoiceCommandMatcher.match(transcript: "skip", on: .question) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "um skip please", on: .question) == .skip)
        // accented mistranscription within the strict floor still counts
        #expect(VoiceCommandMatcher.match(transcript: "skib", on: .question) == .skip)
    }

    @Test("A sentence that merely CONTAINS skip is REJECTED (strict whole-utterance)")
    func strictSkipRejectsContains() {
        // The destructive skip must not fire from a buried token.
        #expect(VoiceCommandMatcher.match(transcript: "let's skip this one", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "can we skip the question", on: .question) == nil)
    }

    // MARK: - Cancel words + UndoWindow

    @Test("Cancel words are recognized")
    func cancelWords() {
        #expect(VoiceCommandLexicon.isCancelWord(VoiceCommandMatcher.normalize("stop")))
        #expect(VoiceCommandLexicon.isCancelWord(VoiceCommandMatcher.normalize("no")))
        #expect(VoiceCommandLexicon.isCancelWord(VoiceCommandMatcher.normalize("cancel")))
        #expect(!VoiceCommandLexicon.isCancelWord(VoiceCommandMatcher.normalize("start")))
    }

    @Test("UndoWindow aborts when cancelled in time, commits once elapsed")
    func undoWindowTiming() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let window = UndoWindow(startedAt: t0, duration: 2.5)

        // Cancel within the window → abort the skip.
        #expect(window.resolve(cancelledAt: t0.addingTimeInterval(1.0)) == .abort)
        // Cancel exactly at the deadline still aborts (inclusive).
        #expect(window.resolve(cancelledAt: t0.addingTimeInterval(2.5)) == .abort)
        // No cancel → commit.
        #expect(window.resolve(cancelledAt: nil) == .commit)
        // Cancel after the deadline is too late → commit.
        #expect(window.resolve(cancelledAt: t0.addingTimeInterval(3.0)) == .commit)
    }

    @Test("UndoWindow.isOpen tracks the deadline")
    func undoWindowIsOpen() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let window = UndoWindow(startedAt: t0, duration: 2.5)
        #expect(window.isOpen(at: t0.addingTimeInterval(1.0)))
        #expect(!window.isOpen(at: t0.addingTimeInterval(2.5)))
        #expect(!window.isOpen(at: t0.addingTimeInterval(5.0)))
    }
}
