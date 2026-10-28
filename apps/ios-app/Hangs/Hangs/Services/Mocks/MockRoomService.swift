//
//  MockRoomService.swift
//  Hangs
//
//  #212: a scripted room for unit tests, UI tests and previews: two questions
//  (A–D, then typed), one more player who always answers, the server's
//  reveal and ranking. The host side starts through `beginGame()` (wired to
//  the mock network's start); a guest's host is driven by `hostStarts()` and
//  `hostMovesOn()`.
//

#if DEBUG
    import Foundation

    @MainActor
    final class MockRoomService: RoomServiceProtocol {
        struct Script {
            var question: Question
            var correctKey: String
            var correctAnswer: String
            var otherAnswer: String
        }

        var nearby: [NearbyRoom] = []
        var createError: Error?
        var joinError: Error?
        /// When set, every poll fails with it (connection loss, a removed player's 404).
        var stateError: Error?
        var revealMode: RoomState.RevealMode = .question
        private(set) var awayReports: [String] = []
        private(set) var answers: [String] = []
        private(set) var removed: [String] = []
        private(set) var openCalls = 0
        private(set) var joinNames: [String] = []

        private var role: RoomViewModel.Role?
        private var players: [RoomState.Player] = []
        private var status: RoomState.Status = .lobby
        private var version = 1
        private var index = -1
        private var phase: RoomState.Round.Phase = .reading
        private var roundAnswers: [String: String] = [:]
        private var closed: [RoomState.Round] = []
        private var finishedReason: String?

        let script: [Script] = [
            Script(
                question: MockRoomService.question(
                    id: "mq1",
                    text: "Which planet has the most known moons?",
                    options: ["a": "Jupiter", "b": "Saturn", "c": "Uranus", "d": "Neptune"]
                ),
                correctKey: "b",
                correctAnswer: "Saturn",
                otherAnswer: "b"
            ),
            Script(
                question: MockRoomService.question(id: "mq2", text: "What is the capital of Australia?", options: nil),
                correctKey: "canberra",
                correctAnswer: "Canberra",
                otherAnswer: "Sydney"
            ),
        ]

        static let roomId = "r_mock"
        static let token = "mock-token"
        static let otherId = "p_other"
        static let youId = "p_you"

        // MARK: - RoomServiceProtocol

        func createRoom(sessionId: String, hostName: String, revealMode: RoomState.RevealMode, thinkingSeconds _: Int) async throws -> RoomCreated {
            if let createError { throw createError }
            role = .host
            self.revealMode = revealMode
            players = [
                .init(participantId: Self.youId, displayName: hostName, color: "#ff6b2c", isHost: true, score: 0),
                .init(participantId: Self.otherId, displayName: "Jana", color: "#7a5cff", isHost: false, score: 0),
            ]
            bump()
            return RoomCreated(roomId: Self.roomId, joinToken: Self.token, sessionId: sessionId)
        }

        func nearbyRooms() async throws -> [NearbyRoom] { nearby }

        func joinRoom(_: RoomInvite, displayName: String) async throws -> RoomState {
            if let joinError { throw joinError }
            joinNames.append(displayName)
            if role == nil {
                role = .guest
                players = [
                    .init(participantId: Self.otherId, displayName: "Michal", color: "#ff6b2c", isHost: true, score: 0),
                    .init(participantId: Self.youId, displayName: displayName, color: "#a3e635", isHost: false, score: 0),
                ]
            } else if let i = players.firstIndex(where: { $0.participantId == Self.youId }) {
                let you = players[i]
                players[i] = .init(participantId: you.participantId, displayName: displayName, color: you.color, isHost: false, score: you.score)
            }
            bump()
            return state(full: true)
        }

        func removePlayer(roomId _: String, participantId: String) async throws {
            removed.append(participantId)
            players.removeAll { $0.participantId == participantId && !$0.isHost }
            bump()
        }

        func roomState(roomId _: String, since: Int?) async throws -> RoomState {
            if let stateError { throw stateError }
            return state(full: since != version)
        }

        func openQuestion(roomId _: String, questionId _: String) async throws -> RoomState {
            openCalls += 1
            if phase == .reading {
                phase = .answering
                bump()
            }
            return state(full: true)
        }

        func answer(roomId _: String, questionId _: String, answer: String) async throws -> RoomState {
            guard phase == .reading || phase == .answering, roundAnswers[Self.youId] == nil else {
                throw NetworkError.serverError(statusCode: 409, message: "Already answered")
            }
            answers.append(answer)
            roundAnswers[Self.youId] = answer
            // The other player always has answered by then: the question closes.
            roundAnswers[Self.otherId] = script[index].otherAnswer
            close()
            return state(full: true)
        }

        func reportAway(roomId _: String, questionId: String) async throws {
            awayReports.append(questionId)
        }

        func nextQuestion(roomId _: String) async throws -> RoomState {
            guard phase == .revealed else { throw NetworkError.serverError(statusCode: 409, message: "Players are still answering") }
            advance()
            return state(full: true)
        }

        // MARK: - Driving the script

        /// The game starts (the host's `/sessions/{id}/start`).
        func beginGame() {
            guard status == .lobby else { return }
            status = .playing
            advance()
        }

        /// A guest's host starts the game and reads the first question.
        func hostStarts() {
            beginGame()
            phase = .answering
            bump()
        }

        /// A guest's host moves on after a reveal.
        func hostMovesOn() {
            guard phase == .revealed else { return }
            advance()
            if status == .playing { phase = .answering }
            bump()
        }

        private func advance() {
            if index + 1 >= script.count {
                status = .finished
                finishedReason = "max_questions"
            } else {
                index += 1
                phase = .reading
                roundAnswers = [:]
            }
            bump()
        }

        private func close() {
            let item = script[index]
            for (pid, answer) in roundAnswers where answer.lowercased() == item.correctKey {
                if let i = players.firstIndex(where: { $0.participantId == pid }) {
                    let p = players[i]
                    players[i] = .init(participantId: p.participantId, displayName: p.displayName, color: p.color, isHost: p.isHost, score: p.score + 1)
                }
            }
            phase = .revealed
            closed.append(currentRound(revealed: true))
            bump()
        }

        private func bump() { version += 1 }

        // MARK: - State

        private func currentRound(revealed: Bool) -> RoomState.Round {
            let item = script[index]
            return RoomState.Round(
                questionId: item.question.id,
                number: index + 1,
                questionText: item.question.question,
                phase: phase,
                remainingMs: phase == .answering ? 20000 : (phase == .revealed ? 0 : nil),
                answered: Array(roundAnswers.keys).sorted(),
                yourAnswer: roundAnswers[Self.youId],
                correctAnswer: revealed ? item.correctAnswer : nil,
                explanation: revealed ? "Mock explanation." : nil,
                results: revealed ? roundAnswers.sorted { $0.key < $1.key }.map { pid, answer in
                    let right = answer.lowercased() == item.correctKey
                    return RoomState.Result(participantId: pid, answer: answer, result: right ? "correct" : "incorrect", points: right ? 1 : 0)
                } : nil
            )
        }

        private func state(full: Bool) -> RoomState {
            guard full else {
                return RoomState(
                    roomId: Self.roomId, version: version, changed: false, status: nil, you: nil, isHost: nil,
                    questionNumber: nil, maxQuestions: nil, players: nil, revealMode: nil, question: nil, round: nil,
                    finishedReason: nil, ranking: nil, rounds: nil, away: nil
                )
            }
            let finished = status == .finished
            let ranked = players.sorted { $0.score > $1.score }
            return RoomState(
                roomId: Self.roomId,
                version: version,
                changed: true,
                status: status,
                you: Self.youId,
                isHost: role == .host,
                questionNumber: index + 1,
                maxQuestions: script.count,
                players: players,
                revealMode: revealMode,
                question: index >= 0 ? script[index].question : nil,
                round: index >= 0 ? currentRound(revealed: phase == .revealed) : nil,
                finishedReason: finishedReason,
                ranking: finished ? ranked.enumerated().map { i, p in
                    RoomState.Rank(participantId: p.participantId, rank: i + 1, score: p.score, correctCount: Int(p.score))
                } : nil,
                rounds: finished ? closed : nil,
                away: finished && role == .host ? [RoomState.Away(participantId: Self.otherId, questions: 1)] : nil
            )
        }

        private static func question(id: String, text: String, options: [String: String]?) -> Question {
            var json: [String: Any] = [
                "id": id, "question": text, "difficulty": "medium", "topic": "mock", "category": "science-nature",
                "type": options == nil ? "text" : "text_multichoice",
            ]
            if let options { json["possible_answers"] = options }
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            // swiftlint:disable:next force_try
            return try! JSONDecoder().decode(Question.self, from: data)
        }
    }
#endif
