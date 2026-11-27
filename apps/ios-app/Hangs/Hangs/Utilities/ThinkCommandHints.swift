//
//  ThinkCommandHints.swift
//  Hangs
//
//  #251 (founder 2026-11-27): the command words during "Think" teach, then
//  fade. They show on the first questions of a quiz, and only in the first
//  quizzes; after that ever more rarely ("po 10, 20, 40 atď."), so a player
//  who forgot them meets them again without the screen naming them for good.
//

import Foundation

enum ThinkCommandHints {
    /// The first questions of a teaching quiz that name the words.
    static let questionsPerQuiz = 3
    /// Quizzes 1...this all teach.
    static let earlyQuizzes = 3
    /// Then this quiz and every doubling of it: 10, 20, 40, 80…
    static let firstSpacedQuiz = 10

    /// Whether the think strip names the command words on question
    /// `questionNumber` (1-based) of the player's `quizOrdinal`-th quiz.
    static func showsWords(quizOrdinal: Int, questionNumber: Int) -> Bool {
        (1 ... questionsPerQuiz).contains(questionNumber) && isTeachingQuiz(quizOrdinal)
    }

    static func isTeachingQuiz(_ ordinal: Int) -> Bool {
        guard ordinal > earlyQuizzes else { return ordinal >= 1 }
        var spaced = firstSpacedQuiz
        while spaced < ordinal {
            spaced *= 2
        }
        return spaced == ordinal
    }
}
