//
//  VoiceCommandMatcherTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.3. These tests pin WHY each
//  matching rule matters for a Slovak-accented driver on a native-English
//  recognizer with NO vocabulary biasing:
//   • routing must be SCREEN-SCOPED (a command inert on the wrong screen must
//     not fire an action that screen doesn't own),
//   • a one-edit near-miss ("anser") must still route to `answer`,
//   • noise must resolve to nil (never guess a wrong action),
//   • `next` is STRICT whole-utterance because skipping burns a question (and
//     since 2026-11-22 it skips at once, no undo), so a sentence that merely
//     CONTAINS "skip" must be rejected.
//  Founder 2026-11-22: four commands (answer, next, repeat, again); confirm,
//  stop, pause, home and the skip undo window are gone.
//

import Foundation
@testable import Hangs
import Testing

@Suite("VoiceCommandMatcher")
struct VoiceCommandMatcherTests {

    // MARK: - Screen-scoped routing

    @Test("Each command routes on the screen that owns it")
    func routesPerScreen() {
        #expect(VoiceCommandMatcher.match(transcript: "answer", on: .question) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "next", on: .question) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "again", on: .confirmation) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "repeat", on: .question) == .repeatQuestion)
    }

    /// WHY (founder 2026-11-22): silence confirms an answer, so the old
    /// "confirm" word is no command. On the sheet it is speech, which the
    /// recognizer treats as a new answer, never as a confirmation.
    @Test("'confirm' is no command on any screen")
    func confirmIsNoCommand() {
        #expect(VoiceCommandMatcher.match(transcript: "confirm", on: .confirmation) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "confirm", on: .question) == nil)
    }

    @Test("A command inert on a screen resolves to nil (scoping)")
    func inertOffScreen() {
        // "next" skips on the question screen, but means nothing on the sheet.
        #expect(VoiceCommandMatcher.match(transcript: "next", on: .confirmation) == nil)
        // "answer" belongs to the question screen, not the confirmation sheet.
        #expect(VoiceCommandMatcher.match(transcript: "answer", on: .confirmation) == nil)
        // "skip" belongs to the question and no-answer screens, not the sheet.
        #expect(VoiceCommandMatcher.match(transcript: "skip", on: .confirmation) == nil)
    }

    /// WHY (#224): the button word IS the command — "Next" skips the question —
    /// and the old words keep working so a driver's habit does not break.
    @Test("'next' skips the question; 'skip' and 'pass' still do too")
    func nextIsTheSkipWord() {
        for word in ["next", "skip", "pass"] {
            #expect(VoiceCommandMatcher.match(transcript: word, on: .question) == .next, "\(word)")
        }
    }

    /// WHY: on the no-answer sheet "next" moves on and "again" re-records; the
    /// two must stay separable so a driver is never sent the wrong way.
    @Test("'next' on the no-answer sheet resolves to next, never to nil")
    func nextOnNoAnswerIsDeterministic() {
        #expect(VoiceCommandMatcher.match(transcript: "next", on: .noAnswer) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "next", on: .noAnswer, isFinal: false) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "again", on: .noAnswer) == .again)
    }

    /// WHY (founder 2026-11-22): confirm is gone, so a reflexive "ok" must
    /// neither confirm nor become the answer: it is filler everywhere.
    @Test("'ok' / 'okay' are filler, never a command")
    func okIsFiller() {
        #expect(VoiceCommandMatcher.match(transcript: "ok", on: .confirmation) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "ok", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "okay", on: .noAnswer) == nil)
        #expect(!VoiceCommandMatcher.hasContentTokens(VoiceCommandMatcher.normalize("okay")))
    }

    // MARK: - Accent tolerance

    @Test("One-edit near-miss 'anser' still routes to answer")
    func accentedNearMiss() {
        // #119 cut the hand-written variant table; the edit-distance floor is
        // what carries these now, which is a ONE-edit tolerance and no more
        // (0.83 against the answer floor of 0.72).
        #expect(VoiceCommandMatcher.match(transcript: "anser", on: .question) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "Anser.", on: .question) == .answer)
        // Two edits on a 5-letter word (0.60) is no command: the strict next
        // floor (0.8) is what keeps radio words like "nekst" from advancing
        // the quiz.
        #expect(VoiceCommandMatcher.match(transcript: "nekst", on: .noAnswer) == nil)
    }

    /// WHY (founder 2026-11-22): each command has its own volatile floor
    /// (again 0.70). A half-heard "aga" scores 0.60 by edit distance: a
    /// volatile hypothesis is revisable and arrives with the mic open to the
    /// road, so it does not fire, but the FINAL gets the truncation credit
    /// (Jaro-Winkler) and does. The real word still fires at once on a
    /// volatile: that is the build-33 latency fix.
    @Test("A truncated word matches on a FINAL but not on a volatile hypothesis")
    func volatileFloorIsStricter() {
        #expect(VoiceCommandMatcher.match(transcript: "aga", on: .confirmation, isFinal: true) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "aga", on: .confirmation, isFinal: false) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "answer", on: .question, isFinal: false) == .answer)
    }

    @Test("Case and diacritics are folded")
    func caseAndDiacriticsFolded() {
        #expect(VoiceCommandMatcher.match(transcript: "  ANSWER ", on: .question) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "Ňext!", on: .question) == .next)
    }

    @Test("Filler words around a command are tolerated")
    func fillerTolerated() {
        #expect(VoiceCommandMatcher.match(transcript: "um answer please", on: .question) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "ok again please", on: .confirmation) == .again)
    }

    // MARK: - Non-command rejection

    @Test("Noise / non-command resolves to nil")
    func noiseRejected() {
        #expect(VoiceCommandMatcher.match(transcript: "hello there", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "the weather is nice", on: .noAnswer) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "...", on: .question) == nil)
    }

    /// WHY (founder 2026-11-22): "start" was retired as the answer word; it
    /// must not linger as a hidden synonym.
    @Test("'start' is no command any more")
    func startIsNoCommand() {
        #expect(VoiceCommandMatcher.match(transcript: "start", on: .question) == nil)
    }

    // MARK: - Strict next

    @Test("Bare 'skip' (± filler) is a next")
    func bareSkipMatches() {
        #expect(VoiceCommandMatcher.match(transcript: "skip", on: .question) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "um skip please", on: .question) == .next)
        // #119: skipping burns a freemium question (and has no undo), so it is
        // held to a near-exact word. A one-edit mangling of a 4-letter word
        // ("skib" = 0.75) does not clear the 0.8 next floor.
        #expect(VoiceCommandMatcher.match(transcript: "skib", on: .question) == nil)
    }

    /// WHY: `next` is the ONE command that may only fire from a final result
    /// (destructive), and the final is precisely the transcript where a driver's
    /// repetitions merge — build-33 verbatim "start start start start start".
    /// If the strict whole-utterance rule counted raw tokens, repeating an
    /// unanswered "skip" would make skip permanently unreachable.
    @Test("A repeated 'skip' is still a next (duplicates collapse in the strict rule too)")
    func repeatedSkipStillMatches() {
        #expect(VoiceCommandMatcher.match(transcript: "skip skip", on: .question) == .next)
        #expect(VoiceCommandMatcher.match(transcript: "skip skip skip", on: .question) == .next)
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
        #expect(VoiceCommandMatcher.match(transcript: "answer answer answer answer answer", on: .question) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "answer answer answer answer answer answer answer", on: .question) == .answer)
    }

    /// WHY: verbatim unmatched transcripts from the same field sessions —
    /// passenger conversation and the app's own feedback TTS re-ingested with
    /// the window open. None is a near-miss (best score ~0.50 vs every
    /// command's floor), so no threshold separates them from commands;
    /// utterance LENGTH does, and that stays true when the mic starts hearing
    /// more per batch.
    @Test("Conversational speech is rejected wholesale by the content-token cap")
    func conversationalSpeechRejected() {
        #expect(VoiceCommandMatcher.match(transcript: "what about guys come in", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "he is proud of you", on: .noAnswer) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "you know i m going to talk about asking yes", on: .confirmation) == nil)
    }

    /// WHY: the cap counts CONTENT tokens, not raw ones — a driver padding a
    /// command with filler ("um answer please") is still issuing one command,
    /// and that tolerance must survive the new gate.
    @Test("Filler around a command does not count against the cap")
    func fillerDoesNotCountAgainstCap() {
        #expect(VoiceCommandMatcher.match(transcript: "um answer please", on: .question) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: "well next then", on: .question) == .next)
        // Duplicates collapse by IDENTITY, not adjacency — filler between two
        // repeats of one command word must not push the utterance over the cap.
        #expect(VoiceCommandMatcher.match(transcript: "answer um answer", on: .question) == .answer)
    }

    /// WHY: the cap is ONE content token because every word in this grammar is
    /// one word. At two, any two-word fragment carrying a command-ish token
    /// fires — and "no okej" is an everyday Slovak phrase.
    /// #185: several words pass only when EVERY one is a word of the same
    /// command ("nie, znova") — "no okej" (en: again + a non-command) disagrees.
    @Test("A two-content-token fragment containing a command word is rejected")
    func twoContentTokensRejected() {
        #expect(VoiceCommandMatcher.match(transcript: "no okej", on: .confirmation) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "answer tak", on: .question) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "answr chee", on: .question) == nil)
    }

    /// WHY (#185 5.3, founder 2026-09-24): on the confirmation sheet "no" asks
    /// for the answer again. "stop" is no command since 2026-11-22: the
    /// countdown hold is gone, so it is speech (a new answer).
    @Test("Bare 'no' re-records on the confirmation sheet; 'stop' is no command")
    func bareNoIsAgainStopIsNothing() {
        #expect(VoiceCommandMatcher.match(transcript: "no", on: .confirmation) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "stop", on: .confirmation) == nil)
    }
}
