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
        struct SettingsCall: Equatable {
            var revealMode: RoomState.RevealMode?
            var thinkingSeconds: Int?
            var readsAloud: Bool?
        }

        struct Script {
            var question: Question
            var correctKey: String
            var correctAnswer: String
            var otherAnswer: String
        }

        var nearby: [NearbyRoom] = []
        /// #249.4: what the join reply says about the host's network (nil = unknown).
        var sameNetwork: Bool?
        var createError: Error?
        var joinError: Error?
        /// When set, every poll fails with it (connection loss, a removed player's 404).
        var stateError: Error?
        var revealMode: RoomState.RevealMode = .question
        var thinkingSeconds = 30
        var readsAloud = true
        /// #224: more guests already in the lobby (a full room fits one screen).
        var extraGuests: [String] = []
        /// #232 (5A): nobody joins the new room (the host can still pick its content).
        var hostAlone = false
        /// When set, `updateSettings` fails with it (the host's change is undone).
        var settingsError: Error?
        /// Every `updateSettings` call, for asserting what the host sent.
        private(set) var settingsCalls: [SettingsCall] = []
        private(set) var awayReports: [String] = []
        private(set) var answers: [String] = []
        private(set) var removed: [String] = []
        private(set) var openCalls = 0
        private(set) var pauseCalls: [Bool] = []
        private var holding = false
        private(set) var joinNames: [String] = []
        /// #235.2: hold any call in flight or put it on a bad network.
        let conditions = MockCallConditions<MockRoomCall>()
        /// #240.9: the room each `createRoom` moved (nil = a new room).
        private(set) var moves: [String?] = []
        /// #240.9: the other player answers only on `othersAnswer()`.
        var othersAnswerLater = false
        /// #240.9: once everyone answered the question stays in grading until `finishGrading()`.
        var holdGrading = false
        /// #240.9: question numbers the judge could not grade (cancelled for everyone).
        var cancelledQuestions: Set<Int> = []
        /// #240.9: the awards on the final screen (Jana fastest on 1, the host alone on 2).
        var awards: [RoomState.Award]? = [
            RoomState.Award(kind: "fastest", participantId: MockRoomService.otherId, questionNumber: 1, ms: 2300),
            RoomState.Award(kind: "only_one", participantId: MockRoomService.youId, questionNumber: 2, count: 1),
        ]

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

        func createRoom(
            sessionId: String,
            hostName: String,
            revealMode: RoomState.RevealMode,
            thinkingSeconds: Int,
            readsAloud: Bool,
            movingRoomId: String?
        ) async throws -> RoomCreated {
            try await conditions.simulateNetwork(.createRoom)
            if let createError { throw createError }
            moves.append(movingRoomId)
            if movingRoomId != nil, role == .host {
                // #240.9: the same room, everyone still in it, a fresh game.
                self.revealMode = revealMode
                self.thinkingSeconds = thinkingSeconds
                self.readsAloud = readsAloud
                resetGame()
                return RoomCreated(roomId: Self.roomId, joinToken: Self.token, sessionId: sessionId)
            }
            role = .host
            self.revealMode = revealMode
            self.thinkingSeconds = thinkingSeconds
            self.readsAloud = readsAloud
            players = [
                .init(participantId: Self.youId, displayName: hostName, color: "#ff6b2c", isHost: true, score: 0),
            ]
            if !hostAlone {
                players += [.init(participantId: Self.otherId, displayName: "Jana", color: "#7a5cff", isHost: false, score: 0)]
                    + extraGuests.enumerated().map { offset, name in
                        .init(participantId: "p_guest\(offset)", displayName: name, color: "#2fb67c", isHost: false, score: 0)
                    }
            }
            bump()
            return RoomCreated(roomId: Self.roomId, joinToken: Self.token, sessionId: sessionId)
        }

        func nearbyRooms() async throws -> [NearbyRoom] {
            try await conditions.simulateNetwork(.nearbyRooms)
            return nearby
        }

        func joinRoom(_: RoomInvite, displayName: String) async throws -> RoomState {
            try await conditions.simulateNetwork(.joinRoom)
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
            var joined = state(full: true)
            joined.sameNetwork = sameNetwork
            return joined
        }

        func removePlayer(roomId _: String, participantId: String) async throws {
            try await conditions.simulateNetwork(.removePlayer)
            removed.append(participantId)
            players.removeAll { $0.participantId == participantId && !$0.isHost }
            bump()
        }

        func roomState(roomId _: String, since: Int?) async throws -> RoomState {
            try await conditions.simulateNetwork(.roomState)
            if let stateError { throw stateError }
            return state(full: since != version)
        }

        func openQuestion(roomId _: String, questionId _: String) async throws -> RoomState {
            try await conditions.simulateNetwork(.openQuestion)
            openCalls += 1
            if phase == .reading {
                phase = .answering
                bump()
            }
            return state(full: true)
        }

        func updateSettings(
            roomId _: String,
            revealMode: RoomState.RevealMode?,
            thinkingSeconds: Int?,
            readsAloud: Bool?
        ) async throws -> RoomState {
            try await conditions.simulateNetwork(.updateSettings)
            settingsCalls.append(SettingsCall(revealMode: revealMode, thinkingSeconds: thinkingSeconds, readsAloud: readsAloud))
            if let settingsError { throw settingsError }
            if revealMode != nil, status != .lobby {
                throw NetworkError.serverError(statusCode: 409, message: "The game has started")
            }
            if let revealMode { self.revealMode = revealMode }
            if let thinkingSeconds { self.thinkingSeconds = thinkingSeconds }
            if let readsAloud { self.readsAloud = readsAloud }
            bump()
            return state(full: true)
        }

        func answer(roomId _: String, questionId _: String, answer: String) async throws -> RoomState {
            try await conditions.simulateNetwork(.answer)
            guard phase == .reading || phase == .answering, roundAnswers[Self.youId] == nil else {
                throw NetworkError.serverError(statusCode: 409, message: "Already answered")
            }
            answers.append(answer)
            roundAnswers[Self.youId] = answer
            if othersAnswerLater {
                bump()
                return state(full: true)
            }
            // The other player always has answered by then: the question closes.
            othersAnswer()
            return state(full: true)
        }

        /// The other players' answers arrive: the question closes (or is graded first).
        /// #249.4: a paused question waits for the resume, like the server.
        func othersAnswer() {
            roundAnswers[Self.otherId] = script[index].otherAnswer
            if holding {
                bump()
            } else if holdGrading {
                phase = .grading
                bump()
            } else {
                close()
            }
        }

        func finishGrading() {
            guard phase == .grading else { return }
            close()
        }

        func reportAway(roomId _: String, questionId: String) async throws {
            try await conditions.simulateNetwork(.reportAway)
            awayReports.append(questionId)
        }

        func setPaused(roomId _: String, paused: Bool) async throws -> RoomState {
            try await conditions.simulateNetwork(.setPaused)
            // #249.4: the reveal and an open question pause; not while answers are checked.
            guard status == .playing, phase != .grading else {
                throw NetworkError.serverError(statusCode: 409, message: "Nothing to pause")
            }
            pauseCalls.append(paused)
            setHolding(paused)
            return state(full: true)
        }

        private func setHolding(_ paused: Bool) {
            holding = paused
            bump()
            // Every answer came in during the pause: the question closes on the resume.
            if !paused, phase != .revealed, roundAnswers.count >= players.count { close() }
        }

        func nextQuestion(roomId _: String) async throws -> RoomState {
            // Like URLSession: a cancelled task's request never arrives.
            try Task.checkCancellation()
            try await conditions.simulateNetwork(.nextQuestion)
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

        /// A guest's host phone finished reading aloud: the answer time starts.
        func hostOpens() {
            guard phase == .reading else { return }
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

        /// A guest's host stays on the reveal or pauses the open question (or resumes).
        func hostPauses(_ paused: Bool) {
            guard status == .playing, phase != .grading else { return }
            setHolding(paused)
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
            holding = false
            bump()
        }

        /// A guest's host taps "Play again" on the final screen.
        func hostPlaysAgain() {
            guard status == .finished else { return }
            resetGame()
        }

        private func resetGame() {
            status = .lobby
            index = -1
            phase = .reading
            roundAnswers = [:]
            closed = []
            finishedReason = nil
            holding = false
            players = players.map { .init(participantId: $0.participantId, displayName: $0.displayName, color: $0.color, isHost: $0.isHost, score: 0) }
            bump()
        }

        private var isCancelled: Bool { cancelledQuestions.contains(index + 1) }

        private func close() {
            let item = script[index]
            for (pid, answer) in roundAnswers where answer.lowercased() == item.correctKey && !isCancelled {
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
                    if isCancelled { return RoomState.Result(participantId: pid, answer: answer, result: "skipped", points: 0) }
                    let right = answer.lowercased() == item.correctKey
                    return RoomState.Result(participantId: pid, answer: answer, result: right ? "correct" : "incorrect", points: right ? 1 : 0)
                } : nil,
                paused: holding && phase != .grading ? true : nil,
                cancelled: revealed && isCancelled ? true : nil
            )
        }

        private func state(full: Bool) -> RoomState {
            guard full else {
                return RoomState(
                    roomId: Self.roomId, version: version, changed: false, status: nil, you: nil, isHost: nil,
                    questionNumber: nil, maxQuestions: nil, players: nil, revealMode: nil, thinkingSeconds: nil,
                    readsAloud: nil, question: nil, round: nil,
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
                thinkingSeconds: thinkingSeconds,
                readsAloud: readsAloud,
                question: index >= 0 ? script[index].question : nil,
                round: index >= 0 ? currentRound(revealed: phase == .revealed) : nil,
                finishedReason: finishedReason,
                ranking: finished ? ranked.enumerated().map { i, p in
                    RoomState.Rank(participantId: p.participantId, rank: i + 1, score: p.score, correctCount: Int(p.score))
                } : nil,
                rounds: finished ? closed : nil,
                away: finished && role == .host ? [RoomState.Away(participantId: Self.otherId, questions: 1)] : nil,
                awards: finished ? awards : nil
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
