//
//  VoiceCommandFourCommandsTests.swift
//  HangsTests
//
//  Founder decisions 2026-11-22: voice commands are simplified to four words
//  in the quiz language: next, repeat and answer on the question screen, and
//  again on the answer sheet, the empty-answer sheet and the quiz-end screens.
//  Each command has its own sensitivity: next is strict (it skips at once, no
//  undo), repeat is lenient, again is the most lenient, and answer is fast and
//  fairly lenient but never loses a near tie to next.
//

@testable import Hangs
import Testing

@Suite("Four voice commands (founder 2026-11-22)")
struct VoiceCommandFourCommandsTests {
    // MARK: - The grammar

    /// WHY: the founder cut the grammar to the four commands a player actually
    /// needs; confirm, stop, pause and home are gone (silence confirms, the
    /// toolbar pauses, the buttons leave).
    @Test("only four commands remain")
    func onlyFourCommands() {
        #expect(Set(VoiceCommand.allCases) == [.next, .repeatQuestion, .answer, .again])
    }

    /// WHY: a command heard on a screen it does nothing on is a false fire
    /// waiting to happen, so every screen lists exactly what it acts on.
    @Test("each screen listens for its own commands only")
    func commandsPerScreen() {
        #expect(Set(VoiceCommandLexicon.commands(on: .question)) == [.answer, .repeatQuestion, .next])
        #expect(VoiceCommandLexicon.commands(on: .confirmation) == [.again])
        #expect(Set(VoiceCommandLexicon.commands(on: .noAnswer)) == [.again, .next])
        #expect(VoiceCommandLexicon.commands(on: .error) == [.again])
        #expect(VoiceCommandLexicon.commands(on: .setEnd) == [.again])
    }

    // MARK: - "answer" replaces "start"

    nonisolated static let answerWords: [(CommandLanguage, String)] = [
        (.english, "answer"),
        (.slovak, "odpovedz"), (.slovak, "odpovedaj"), (.slovak, "odpoveď"),
        (.czech, "odpověz"), (.czech, "odpovídej"), (.czech, "odpověď"),
        (.ukrainian, "відповідай"), (.ukrainian, "відповідь"),
    ]

    /// WHY (decision 2): "start" was not intuitive; the word on the Answer
    /// button is what a player says, and its close forms must work too, from
    /// the first stable hypothesis (the command is meant to be fast).
    @Test("the Answer button's word and its close forms open the answer", arguments: answerWords)
    func answerWordOpensAnswer(_ language: CommandLanguage, _ word: String) {
        #expect(VoiceCommandMatcher.match(transcript: word, on: .question, isFinal: true, language: language) == .answer)
        #expect(VoiceCommandMatcher.match(transcript: word, on: .question, isFinal: false, language: language) == .answer)
    }

    /// WHY: the old word must not keep working as a hidden synonym, or the
    /// grammar did not get simpler.
    @Test("'start' no longer opens the answer", arguments: [
        (CommandLanguage.english, "start"), (.slovak, "štart"), (.czech, "start"), (.ukrainian, "старт"),
    ])
    func startIsGone(_ language: CommandLanguage, _ word: String) {
        #expect(VoiceCommandMatcher.match(transcript: word, on: .question, language: language) == nil)
    }

    nonisolated static let removedWords: [(CommandLanguage, VoiceCommandScreen, String)] = [
        (.english, .confirmation, "ok"), (.english, .confirmation, "confirm"), (.english, .confirmation, "yes"),
        (.english, .confirmation, "stop"), (.english, .confirmation, "pause"), (.english, .setEnd, "home"),
        (.english, .error, "stop"), (.english, .question, "pause"),
        (.slovak, .confirmation, "potvrď"), (.slovak, .confirmation, "áno"), (.slovak, .confirmation, "stop"),
        (.slovak, .confirmation, "pauza"), (.slovak, .setEnd, "domov"), (.slovak, .setEnd, "úvod"),
        (.czech, .confirmation, "potvrď"), (.czech, .confirmation, "pauza"), (.czech, .setEnd, "domů"),
        (.ukrainian, .confirmation, "підтверди"), (.ukrainian, .confirmation, "пауза"), (.ukrainian, .setEnd, "додому"),
    ]

    /// WHY (decision 1): confirm, stop, pause and home are removed. On the
    /// answer sheet such a word is now simply speech (a new answer or noise),
    /// never a command.
    @Test("removed words are no command anywhere", arguments: removedWords)
    func removedWordsAreInert(_ language: CommandLanguage, _ screen: VoiceCommandScreen, _ word: String) {
        #expect(VoiceCommandMatcher.match(transcript: word, on: screen, isFinal: true, language: language) == nil)
    }

    // MARK: - Sensitivity (decision 3)

    /// WHY: the founder ranked the commands by what a false fire costs. Next
    /// skips the question at once, so it is the strictest; repeat only
    /// replays; again only asks for the answer the player is giving anyway,
    /// so it is the most lenient. The ordering must hold for finals and for
    /// volatile hypotheses alike.
    @Test("next is stricter than repeat, repeat stricter than again")
    func sensitivityOrdering() {
        let next = VoiceCommand.next.sensitivity
        let repeatQuestion = VoiceCommand.repeatQuestion.sensitivity
        let again = VoiceCommand.again.sensitivity
        #expect(next.finalFloor > repeatQuestion.finalFloor)
        #expect(repeatQuestion.finalFloor > again.finalFloor)
        #expect(next.volatileFloor > repeatQuestion.volatileFloor)
        #expect(repeatQuestion.volatileFloor > again.volatileFloor)
        // answer is fast and fairly lenient: between next and repeat.
        let answer = VoiceCommand.answer.sensitivity
        #expect(next.finalFloor > answer.finalFloor && answer.finalFloor >= repeatQuestion.finalFloor)
    }

    /// WHY: next may wait for the final (precision over speed); the lenient
    /// commands must never wait for one, on any screen. "Again" on the
    /// set-end screen used to wait ~2 s.
    @Test("only next waits for a final result, on every screen")
    func onlyNextWaitsForFinal() {
        let screens: [VoiceCommandScreen] = [.question, .confirmation, .noAnswer, .error, .setEnd]
        for screen in screens {
            for command in VoiceCommandLexicon.commands(on: screen) {
                #expect(
                    VoiceCommandCoordinator.requiresFinalResult(command, on: screen) == (command == .next),
                    "\(command) on \(screen)"
                )
            }
        }
    }

    /// WHY: a lenient command catches an imperfect match: a one-letter slip
    /// on "znova" still re-records, while the same slip on the skip word does
    /// not skip.
    @Test("again catches an imperfect word that next would refuse")
    func againIsLenientNextIsStrict() {
        // A cut-off "again" (0.8) on a volatile hypothesis: the old shared
        // volatile floor (0.85) refused it.
        #expect(VoiceCommandMatcher.match(transcript: "agai", on: .confirmation, isFinal: false, language: .english) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "znoa", on: .confirmation, isFinal: true, language: .slovak) == .again)
        // The same one-letter slip on the skip word does not skip.
        #expect(VoiceCommandMatcher.match(transcript: "nekst", on: .question, isFinal: true, language: .english) == nil)
        #expect(VoiceCommandMatcher.match(transcript: "skib", on: .question, isFinal: true, language: .english) == nil)
    }

    /// WHY (PR review): "again" is the most lenient, but a one-letter slip on
    /// a three-letter word is a different word, not a misheard command: on the
    /// answer sheet "Níl" (the Nile) or "ale" is the player's new answer, and
    /// reading it as "again" would throw that answer away.
    @Test("a short word one letter from a short again word is not again", arguments: [
        ("nil", CommandLanguage.slovak), ("ale", .slovak), ("zlo", .slovak),
        ("now", .english), ("not", .english),
    ])
    func shortNearMissIsNotAgain(word: String, language: CommandLanguage) {
        #expect(VoiceCommandMatcher.match(transcript: word, on: .confirmation, isFinal: true, language: language) == nil)
    }

    @Test("the short again words still count when heard exactly")
    func shortAgainWordsExact() {
        #expect(VoiceCommandMatcher.match(transcript: "nie", on: .confirmation, isFinal: true, language: .slovak) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "zle", on: .confirmation, isFinal: true, language: .slovak) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "no", on: .confirmation, isFinal: true, language: .english) == .again)
        #expect(VoiceCommandMatcher.match(transcript: "ne", on: .confirmation, isFinal: true, language: .czech) == .again)
    }

    // MARK: - Near ties (decision 3, answer vs next)

    /// WHY: answer competes with next and repeat in the same window. A word
    /// close to two commands must resolve to the less destructive one, and
    /// never to next: a wrong skip loses the question, a wrong answer or
    /// repeat is undone by speaking.
    @Test("a near tie never resolves to next")
    func nearTieNeverNext() {
        #expect(VoiceCommandMatcher.resolve([(.next, 0.95), (.answer, 0.9)], isFinal: true) == .answer)
        #expect(VoiceCommandMatcher.resolve([(.next, 0.95), (.repeatQuestion, 0.9)], isFinal: true) == .repeatQuestion)
        #expect(VoiceCommandMatcher.resolve([(.next, 0.9), (.again, 0.85)], isFinal: true) == .again)
        #expect(VoiceCommandMatcher.resolve([(.answer, 0.9), (.repeatQuestion, 0.88)], isFinal: true) == .repeatQuestion)
    }

    /// WHY: the tie rule must not swallow a clear next: when nothing else is
    /// close, next fires.
    @Test("a clear next still wins")
    func clearNextWins() {
        #expect(VoiceCommandMatcher.resolve([(.next, 1.0), (.answer, 0.5), (.repeatQuestion, 0.3)], isFinal: true) == .next)
        #expect(VoiceCommandMatcher.resolve([(.next, 0.79)], isFinal: true) == nil, "below the strict floor")
    }
}
