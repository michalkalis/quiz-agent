//
//  RoomViewModel+Host.swift
//  Hangs
//
//  #212: the host's phone runs the game: creates the room from its own
//  session, reads each question aloud, starts the answer time, moves on.
//

import Foundation
import os

extension RoomViewModel {
    static var genericMessage: String {
        String(localized: "Something went wrong. Try again.", bundle: .interface, locale: .interface, comment: "Hra spolu: an action failed, e.g. creating or answering")
    }

    static func joinMessage(for error: Error) -> String {
        switch error {
        case NetworkError.serverError(statusCode: 404, _):
            String(localized: "This game is no longer open.", bundle: .interface, locale: .interface, comment: "Hra spolu: joining failed, the game ended or the link is old")
        case NetworkError.serverError(statusCode: 409, _):
            String(localized: "This game is full or already over.", bundle: .interface, locale: .interface, comment: "Hra spolu: joining failed, 8 players or finished")
        default:
            genericMessage
        }
    }

    /// In the round-reveal mode there is nothing to look at between questions.
    static let roundModePauseSeconds = 3

    /// The host's name: the account's first name, else the one typed before.
    var hostName: String? { accountName ?? names.chosenName }

    /// Starts hosting; without a name to show, asks for one first.
    func beginHosting() async {
        guard let name = hostName else {
            isAskingHostName = true
            return
        }
        await host(as: name)
    }

    func confirmHostName(_ name: String) async {
        guard let clean = PlayerNameStore.cleaned(name) else { return }
        isAskingHostName = false
        await rename(to: clean)
        await host(as: clean)
    }

    private func host(as name: String) async {
        stopNearbySearch()
        role = .host
        isWorking = true
        defer { isWorking = false }
        do {
            let session = try await network.createSession(
                maxQuestions: solo.numberOfQuestions,
                difficulty: solo.difficulty,
                language: Language.selectable(solo.language).id,
                categories: solo.categories,
                userId: deviceId,
                includeImages: MultiplayerSettings.includeImageQuestions,
                skipLocalQuestions: !solo.includeLocalQuestions,
                packId: nil
            )
            created = try await rooms.createRoom(
                sessionId: session.id,
                hostName: name,
                revealMode: settings.revealMode,
                thinkingSeconds: settings.thinkingSeconds,
                readsAloud: settings.readsAloud
            )
            await refresh()
            startPolling()
        } catch {
            Logger.network.error("Room create failed: \(error, privacy: .public)")
            role = nil
            created = nil
            errorMessage = Self.genericMessage
            startNearbySearch()
        }
    }

    func remove(_ player: RoomState.Player) async {
        guard isHost, !player.isHost, let roomId = created?.roomId else { return }
        do {
            try await rooms.removePlayer(roomId: roomId, participantId: player.participantId)
            await refresh()
        } catch {
            errorMessage = Self.genericMessage
        }
    }

    /// Starts the game for everyone, the first question like a solo start.
    func startGame() async {
        guard isHost, let created else { return }
        isWorking = true
        defer { isWorking = false }
        if settings.readsAloud { prepareReadAloudAudio() }
        do {
            let response = try await network.startQuiz(
                sessionId: created.sessionId,
                excludedQuestionIds: excludedQuestionIds()
            )
            questionAudioPath = response.audio?.questionUrl
            await refresh()
        } catch NetworkError.quotaLimitReached {
            quotaReached = true
        } catch {
            errorMessage = Self.genericMessage
        }
    }

    func prepareReadAloudAudio() {
        do { try audio.setupAudioSession(mode: audioMode) } catch {
            Logger.audio.warning("Room audio session setup failed: \(error, privacy: .public)")
        }
    }

    /// The next question for everyone, or the final ranking.
    func next() async {
        guard isHost, !isWorking else { return }
        advanceTask?.cancel()
        autoAdvanceLeft = nil
        await moveOn()
    }

    /// The request itself. The auto-advance calls it from its own task, so it
    /// must not cancel that task (a cancelled request never reaches the server).
    private func moveOn() async {
        guard let roomId = created?.roomId else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try apply(await rooms.nextQuestion(roomId: roomId))
        } catch NetworkError.serverError(statusCode: 409, _) {
            await refresh()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            errorMessage = Self.genericMessage
        }
    }

    /// Reads the question aloud again; the answer time keeps running.
    func readAgain() {
        guard isHost, settings.readsAloud, !isReadingAloud else { return }
        Task { await readAloud() }
    }

    func hostReact(to state: RoomState) {
        guard state.status == .playing, let round = state.round else { return }
        if round.phase == .reading, readQuestionId != round.questionId {
            readQuestionId = round.questionId
            readTask?.cancel()
            readTask = Task { await readAloudAndOpen(questionId: round.questionId) }
        }
        if round.phase == .revealed, advanceQuestionId != round.questionId {
            advanceQuestionId = round.questionId
            let seconds = state.revealMode == .round ? Self.roundModePauseSeconds : autoAdvanceSeconds
            scheduleAutoAdvance(after: seconds)
        }
    }

    private func readAloudAndOpen(questionId: String) async {
        if settings.readsAloud { await readAloud() }
        guard !Task.isCancelled, let roomId = created?.roomId else { return }
        do {
            try apply(await rooms.openQuestion(roomId: roomId, questionId: questionId))
        } catch {
            // The server starts the time by itself after a while; the next poll shows it.
            Logger.network.warning("Room open failed: \(error, privacy: .public)")
        }
    }

    private func readAloud() async {
        guard let created else { return }
        let path = questionAudioPath ?? "/api/v1/sessions/\(created.sessionId)/question/audio"
        isReadingAloud = true
        defer { isReadingAloud = false }
        do {
            let data = try await network.downloadAudio(from: path)
            _ = try await audio.playOpusAudio(data)
        } catch {
            Logger.audio.warning("Room read-aloud failed: \(error, privacy: .public)")
        }
    }

    private func scheduleAutoAdvance(after seconds: Int) {
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            guard let self else { return }
            for left in stride(from: seconds, to: 0, by: -1) {
                autoAdvanceLeft = left
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
            }
            autoAdvanceLeft = nil
            guard !isWorking else { return }
            await moveOn()
        }
    }
}
