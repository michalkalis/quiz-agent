//
//  VoiceCommandFuzzyMatchTests.swift
//  HangsTests
//
//  Issue #184 track E — the car-noise recall work on the command matcher. The
//  founder's field test (Slovak, moving car) found commands only worked when
//  SHOUTED: a half-heard command loses its TAIL, and Levenshtein divides by the
//  longer word's length, so a truncation is punished exactly as hard as a
//  wrong word. These tests pin the two additions that fix that and the guard
//  rail that keeps #119's false-fire protection intact:
//   • Jaro-Winkler rewards a surviving PREFIX, so a truncated command routes,
//   • but ONLY on a final — a volatile keeps the Levenshtein-only floor #119
//     tuned on field data, or "star"→"start" re-opens the noise hole,
//   • and the sk/cs phonetic fold makes spelling flips the driver never hears
//     (y/i, doubled letters) cost nothing, while English is left untouched.
//

import Foundation
@testable import Hangs
import Testing

@Suite("VoiceCommandMatcher — #184 fuzzy scoring")
struct VoiceCommandFuzzyMatchTests {

    // MARK: - Jaro-Winkler

    /// WHY these exact numbers: they are the metric's published reference values.
    /// If the implementation drifts (window size, transposition halving, prefix
    /// cap) every recall decision downstream shifts silently — this is the pin.
    @Test("Jaro-Winkler matches its reference values")
    func jaroWinklerReferenceValues() {
        #expect(abs(VoiceCommandMatcher.jaroWinkler("martha", "marhta") - 0.961) < 0.001)
        #expect(abs(VoiceCommandMatcher.jaroWinkler("dwayne", "duane") - 0.840) < 0.001)
        #expect(VoiceCommandMatcher.jaroWinkler("start", "start") == 1.0)
        // Nothing in common — the score must be a hard 0, not a small positive
        // number that could creep over a floor when stacked with a low bar.
        #expect(VoiceCommandMatcher.jaroWinkler("abc", "xyz") == 0.0)
    }

    /// WHY: an empty transcript must never score as a match against anything.
    @Test("An empty string scores 0 against a real word")
    func jaroWinklerEmpty() {
        #expect(VoiceCommandMatcher.jaroWinkler("", "start") == 0.0)
        #expect(VoiceCommandMatcher.jaroWinkler("", "") == 1.0)
    }

    // MARK: - Truncation: final vs volatile

    /// WHY: this IS the #184 field failure. "znova" half-heard over road noise
    /// arrives as "zno"; Levenshtein scores it 0.60 — below the 0.72 final floor
    /// — so the founder had to shout. Jaro-Winkler scores the surviving prefix
    /// 0.91 and the command routes.
    @Test("A truncated Slovak command routes on a final, where Levenshtein alone would not")
    func truncatedSlovakCommandRoutesOnFinal() {
        #expect(
            VoiceCommandMatcher.similarity("zno", "znova") < VoiceCommandMatcher.confidenceFloor,
            "the premise: Levenshtein alone rejects this truncation"
        )
        #expect(
            VoiceCommandMatcher.match(
                transcript: "zno", on: .confirmation, isFinal: true, language: .slovak
            ) == .again
        )
    }

    /// WHY the conflict is resolved this way: a volatile hypothesis is revisable
    /// and arrives while the mic is still open to the road and the passenger, so
    /// #119 holds it to a near-exact floor. Jaro-Winkler on a volatile would
    /// score any sentence's one-word prefix generously and re-open exactly that
    /// hole. `again` also discards a transcribed answer — it may only fire from
    /// a final anyway.
    @Test("The same truncation is still rejected as a volatile hypothesis")
    func truncatedSlovakCommandRejectedOnVolatile() {
        #expect(
            VoiceCommandMatcher.match(
                transcript: "zno", on: .confirmation, isFinal: false, language: .slovak
            ) == nil
        )
    }

    /// WHY: the #119 regression guard. "star" (radio, "Starting now…") must stay
    /// below the volatile floor although Jaro-Winkler rates it ~0.96 — proving
    /// the combined scorer really is final-only.
    @Test("'star' does not start the quiz from a volatile hypothesis (#119 guard)")
    func starDoesNotStartFromVolatile() {
        #expect(VoiceCommandMatcher.jaroWinkler("star", "start") > 0.9, "the premise: JW loves this pair")
        #expect(VoiceCommandMatcher.match(transcript: "star", on: .home, isFinal: false) == nil)
    }

    /// WHY the JW term is scoped to SHORTER-than-variant tokens: at equal
    /// length Levenshtein is already fair, so JW would only loosen — and it
    /// loosens on exactly the near-misses #119's field data rejected. "skib"
    /// scores 0.88 under JW and would burn a freemium question; "nekst" scores
    /// 0.83 and would advance the quiz.
    @Test("A same-length near-miss stays rejected on a final (#119 guard)")
    func sameLengthNearMissStaysRejected() {
        #expect(VoiceCommandMatcher.jaroWinkler("skib", "skip") > 0.8, "the premise: JW would accept it")
        #expect(VoiceCommandMatcher.match(transcript: "skib", on: .question, isFinal: true) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "nekst", on: .result, isFinal: true) == nil)
    }

    /// WHY a shared HEAD is required too: Jaro-Winkler divides matches by the
    /// TOKEN's length, so a 2-letter word scores ~0.8 against any long word
    /// that merely contains its letters. The Czech backchannel "no" rates 0.80
    /// against "znovu" and would RE-RECORD the founder's answer mid
    /// conversation. A half-heard command loses its tail, never its head.
    @Test("A short backchannel does not become a truncated command (#175 precision)")
    func shortBackchannelIsNotATruncation() {
        #expect(VoiceCommandMatcher.jaroWinkler("no", "znovu") > 0.79, "the premise: JW would accept it")
        #expect(
            VoiceCommandMatcher.match(
                transcript: "no", on: .confirmation, isFinal: true, language: .czech
            ) == nil
        )
    }

    // MARK: - sk/cs phonetic fold

    /// WHY: the on-device sk/cs recognizer flips spellings a Slovak speaker
    /// never hears apart (y/i above all), and doubles letters on a drawn-out
    /// vowel. Each flip costs a full edit, and on a 5-letter command word one
    /// edit is most of the budget.
    @Test("Slovak normalisation folds y→i, w→v, q→k, x→ks and collapses doubled letters")
    func slovakPhoneticFold() {
        #expect(VoiceCommandMatcher.normalize("znovy", language: .slovak) == "znovi")
        #expect(VoiceCommandMatcher.normalize("znowa", language: .slovak) == "znova")
        #expect(VoiceCommandMatcher.normalize("preskkoč", language: .slovak) == "preskoc")
        #expect(VoiceCommandMatcher.normalize("qauza", language: .slovak) == "kauza")
        #expect(VoiceCommandMatcher.normalize("xero", language: .slovak) == "ksero")
        // Czech shares the design (same recognizer, same hazards).
        #expect(VoiceCommandMatcher.normalize("znovy", language: .czech) == "znovi")
    }

    /// WHY English is excluded: its command set was tuned on #119 field data
    /// with NO fold, and folding would erase real distinctions there ("retry"
    /// → "retri") while buying nothing — the en-US model renders command words
    /// letter-perfect.
    @Test("English normalisation is unchanged by the fold")
    func englishNormalisationUntouched() {
        #expect(VoiceCommandMatcher.normalize("retry") == "retry")
        #expect(VoiceCommandMatcher.normalize("skipp") == "skipp")
        #expect(VoiceCommandMatcher.normalize("Okay, next!") == "okay next")
    }

    /// WHY end-to-end: the fold is only worth anything if the LEXICON goes
    /// through it too — the variants are stored in dictionary spelling, so a
    /// folded transcript would otherwise be scored against an unfolded word.
    @Test("A y/i mishearing of a Slovak command still routes")
    func foldedMishearingRoutes() {
        #expect(
            VoiceCommandMatcher.match(
                transcript: "znovy", on: .confirmation, isFinal: true, language: .slovak
            ) == .again
        )
        #expect(
            VoiceCommandMatcher.match(
                transcript: "pauzza", on: .confirmation, isFinal: true, language: .slovak
            ) == .pause
        )
    }

    /// WHY: the filler list is compared AFTER normalisation, so it has to be
    /// folded by the same step — otherwise a Slovak backchannel survives the
    /// fold, counts as a content token, and the one-token cap starts rejecting
    /// real commands spoken with padding.
    @Test("Slovak filler still strips after the phonetic fold")
    func fillerSurvivesTheFold() {
        let normalized = VoiceCommandMatcher.normalize("dobre znova", language: .slovak)
        #expect(
            VoiceCommandMatcher.match(
                transcript: normalized, on: .confirmation, isFinal: true, language: .slovak
            ) == .again
        )
    }
}
