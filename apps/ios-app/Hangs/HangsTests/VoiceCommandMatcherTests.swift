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
        // #119 cut the hand-written variant table ("stat"/"staat"/"nekst" were
        // literal entries); the edit-distance floor is what carries these now,
        // which is a ONE-edit tolerance and no more.
        #expect(VoiceCommandMatcher.match(transcript: "stat", on: .question) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "Staat.", on: .home) == .start)
        // Two edits on a 5-letter word (0.60) is no longer a command: the
        // speculative "nekst" entry is exactly what made radio words "nek" and
        // "nekst" advance the quiz, and the field data shows a real command word
        // transcribes perfectly, so the tolerance bought nothing.
        #expect(VoiceCommandMatcher.match(transcript: "nekst", on: .result) == nil)
    }

    /// WHY: a volatile hypothesis is revisable and arrives with the mic open to
    /// the road, the radio and the passenger, so it may only act on a near-exact
    /// word. A one-edit score (0.80) is what lifts noise like "star"/"gain" over
    /// the final-result floor; nothing real is lost, because the field data puts
    /// a genuine command word at 1.00 and the unmatched conversation at ~0.50.
    @Test("A one-edit near-miss matches on a FINAL but not on a volatile hypothesis")
    func volatileFloorIsStricter() {
        #expect(VoiceCommandMatcher.match(transcript: "stat", on: .home, isFinal: true) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "stat", on: .home, isFinal: false) == nil)
        // The real word still fires immediately on a volatile — that IS the
        // build-33 latency fix, and it must not be collateral damage.
        #expect(VoiceCommandMatcher.match(transcript: "start", on: .home, isFinal: false) == .start)
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
        // #119: skipping burns a freemium question, so it is held to a near-exact
        // word. With the speculative accent variants gone, a one-edit mangling of
        // a 4-letter word ("skib" = 0.75) no longer clears the 0.8 skip floor.
        #expect(VoiceCommandMatcher.match(transcript: "skib", on: .question) == nil)
    }

    /// WHY: `skip` is the ONE command that may only fire from a final result
    /// (destructive), and the final is precisely the transcript where a driver's
    /// repetitions merge — build-33 verbatim "start start start start start".
    /// If the strict whole-utterance rule counted raw tokens, repeating an
    /// unanswered "skip" would make skip permanently unreachable.
    @Test("A repeated 'skip' is still a skip (duplicates collapse in the strict rule too)")
    func repeatedSkipStillMatches() {
        #expect(VoiceCommandMatcher.match(transcript: "skip skip", on: .question) == .skip)
        #expect(VoiceCommandMatcher.match(transcript: "skip skip skip", on: .question) == .skip)
    }

    @Test("A sentence that merely CONTAINS skip is REJECTED (strict whole-utterance)")
    func strictSkipRejectsContains() {
        // The destructive skip must not fire from a buried token.
        #expect(VoiceCommandMatcher.match(transcript: "let's skip this one", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "can we skip the question", on: .question) == nil)
    }

    // MARK: - Content-token cap (#119, build-33 field data)

    /// WHY: the Sentry build-33 transcripts contain verbatim "start start start
    /// start start" — the founder repeating an unanswered command. The cap must
    /// count a repeated word ONCE, or the precision fix would kill the single
    /// most common shape of a REAL command.
    @Test("A repeated command word still matches (consecutive duplicates collapse)")
    func repeatedCommandWordStillMatches() {
        #expect(VoiceCommandMatcher.match(transcript: "start start start start start", on: .home) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "start start start start start start start", on: .home) == .start)
    }

    /// WHY: verbatim unmatched transcripts from the same field sessions —
    /// passenger conversation and the app's own feedback TTS re-ingested with
    /// the window open. None is a near-miss (best score ~0.50 vs the 0.72
    /// floor), so no threshold separates them from commands; utterance LENGTH
    /// does, and that stays true when the mic starts hearing more per batch.
    @Test("Conversational speech is rejected wholesale by the content-token cap")
    func conversationalSpeechRejected() {
        #expect(VoiceCommandMatcher.match(transcript: "what about guys come in", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "he is proud of you", on: .result) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "you know i m going to talk about asking yes", on: .confirmation) == nil)
    }

    /// WHY: the cap counts CONTENT tokens, not raw ones — a driver padding a
    /// command with filler ("um start please") is still issuing one command,
    /// and that tolerance must survive the new gate.
    @Test("Filler around a command does not count against the cap")
    func fillerDoesNotCountAgainstCap() {
        #expect(VoiceCommandMatcher.match(transcript: "um start please", on: .home) == .start)
        #expect(VoiceCommandMatcher.match(transcript: "well next then", on: .result) == .next)
        // Duplicates collapse by IDENTITY, not adjacency — filler between two
        // repeats of one command word must not push the utterance over the cap.
        #expect(VoiceCommandMatcher.match(transcript: "start um start", on: .home) == .start)
    }

    /// WHY: the cap is ONE content token because every word in this grammar is
    /// one word. At two, any two-word fragment carrying a command-ish token
    /// fires — and "no okej" is an everyday Slovak phrase that would have
    /// submitted the answer on the confirmation sheet (0.80 against `.ok`).
    /// Precision here is what lets the benign commands act on a volatile at all.
    @Test("A two-content-token fragment containing a command word is rejected")
    func twoContentTokensRejected() {
        #expect(VoiceCommandMatcher.match(transcript: "no okej", on: .confirmation) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "okay tak", on: .result) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "stat chee", on: .home) == nil)
    }

    /// WHY: "no" is a top-frequency Slovak discourse particle (~"well/so") and
    /// the founder speaks Slovak to passengers with the mic open. A false
    /// `.stop` on the confirmation sheet calls cancelProcessing() and discards
    /// an in-flight answer with NO undo — so bare "no" must not reach `.stop`
    /// through the matcher, while the fail-safe undo-abort path still takes it.
    @Test("Bare 'no' is not a stop command on the confirmation sheet")
    func bareNoIsNotStop() {
        #expect(VoiceCommandMatcher.match(transcript: "no", on: .confirmation) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "stop", on: .confirmation) == .stop)
        #expect(VoiceCommandLexicon.isCancelWord("no"), "aborting a skip is fail-safe — that path keeps 'no'")
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
