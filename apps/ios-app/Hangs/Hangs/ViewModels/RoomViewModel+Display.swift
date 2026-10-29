//
//  RoomViewModel+Display.swift
//  Hangs
//
//  #212: the rows the reveal and final screens draw, prepared from the room.
//

import Foundation

extension RoomViewModel {
    /// One player's line in a reveal: what they answered (nil = no answer in time).
    struct RevealRow: Identifiable, Equatable {
        let id: String
        let name: String
        let color: String?
        let answer: String?
        let isCorrect: Bool
        let points: Double
        let isYou: Bool
    }

    struct RankRow: Identifiable, Equatable {
        let id: String
        let rank: Int
        let name: String
        let color: String?
        let correctCount: Int
        let isYou: Bool
    }

    /// Host only: who left the app during how many questions.
    struct AwayRow: Identifiable, Equatable {
        let id: String
        let name: String
        let questions: Int
    }

    /// One question of the game for the round-reveal summary at the end.
    struct RoundSummary: Identifiable, Equatable {
        let id: String
        let number: Int
        let questionText: String
        let correctAnswer: String?
        let yourAnswer: String?
        let youWereRight: Bool
        let correctCount: Int
    }

    func name(of participantId: String) -> String {
        players.first { $0.participantId == participantId }?.displayName ?? "?"
    }

    /// A tapped option travels as its key; people read the option's text.
    func answerText(_ raw: String, questionId: String) -> String {
        guard let options = questionsById[questionId]?.possibleAnswers else { return raw }
        return options[raw] ?? options[raw.lowercased()] ?? raw
    }

    func revealRows(for round: RoomState.Round) -> [RevealRow] {
        let results = Dictionary((round.results ?? []).map { ($0.participantId, $0) }, uniquingKeysWith: { first, _ in first })
        return players.map { player in
            let result = results[player.participantId]
            return RevealRow(
                id: player.participantId,
                name: player.displayName,
                color: player.color,
                answer: result.map { answerText($0.answer, questionId: round.questionId) },
                isCorrect: result?.isCorrect ?? false,
                points: result?.points ?? 0,
                isYou: player.participantId == state?.you
            )
        }
    }

    /// "Vedeli 2 zo 4": correct answers out of the players in the room.
    func correctCount(in round: RoomState.Round) -> Int {
        (round.results ?? []).count(where: \.isCorrect)
    }

    var rankRows: [RankRow] {
        (state?.ranking ?? []).map { rank in
            let player = players.first { $0.participantId == rank.participantId }
            return RankRow(
                id: rank.participantId,
                rank: rank.rank,
                name: player?.displayName ?? "?",
                color: player?.color,
                correctCount: rank.correctCount,
                isYou: rank.participantId == state?.you
            )
        }
    }

    var awayRows: [AwayRow] {
        (state?.away ?? []).filter { $0.questions > 0 }.map {
            AwayRow(id: $0.participantId, name: name(of: $0.participantId), questions: $0.questions)
        }
    }

    var roundSummaries: [RoundSummary] {
        let you = state?.you
        return (state?.rounds ?? []).map { round in
            let mine = round.results?.first { $0.participantId == you }
            return RoundSummary(
                id: round.questionId,
                number: round.number,
                questionText: round.questionText,
                correctAnswer: round.correctAnswer,
                yourAnswer: (mine?.answer ?? round.yourAnswer).map { answerText($0, questionId: round.questionId) },
                youWereRight: mine?.isCorrect ?? false,
                correctCount: correctCount(in: round)
            )
        }
    }

    /// The answer this phone sent for the open question, as text.
    var yourAnswerText: String? {
        guard let round, let raw = round.yourAnswer ?? submittingAnswer else { return nil }
        return answerText(raw, questionId: round.questionId)
    }
}
