//
//  RoomViewModel+Endgame.swift
//  Hangs
//
//  #240.9 (founder 2026-11-18): no silent waiting while a question is read
//  or graded, and an end with more than one moment: small awards, a picture
//  of the ranking to send, and "Play again" with the same people.
//

import Clocks
import Foundation
import os

extension RoomViewModel {
    // MARK: - Waiting

    /// What the player's own answer to the revealed question came to.
    enum RevealOutcome: Equatable { case correct, miss, cancelled }

    /// How long a question takes to read aloud, estimated from its text: the
    /// host's phone does not tell the room how long its clip is. Kept short
    /// of the end, so the bar never claims the answer time already started.
    static let readCharactersPerSecond = 14.0
    static let readLeadInSeconds = 1.5
    static let readEstimateRange = 3.0 ... 30.0
    static let readingCap = 0.95

    static func readingEstimate(for question: Question?) -> Duration {
        let options = question?.possibleAnswers?.values.joined(separator: " ") ?? ""
        let characters = Double((question?.question.count ?? 0) + options.count)
        let seconds = characters / readCharactersPerSecond + readLeadInSeconds
        let bounded = min(max(seconds, readEstimateRange.lowerBound), readEstimateRange.upperBound)
        return .milliseconds(Int(bounded * 1000))
    }

    /// 0…1 while the question is read aloud; nil otherwise.
    func readingProgress() -> Double? {
        guard round?.phase == .reading, let readingSince else { return nil }
        let elapsed = readingSince.duration(to: clock.now)
        return min(Self.readingCap, max(0, elapsed / Self.readingEstimate(for: question)))
    }

    /// Everyone answered and the answers are being checked.
    var isGrading: Bool { round?.phase == .grading }

    /// Who already answered the open question, in player order (never what).
    var answeredNames: [String] {
        guard let round else { return [] }
        return players.filter { round.answered.contains($0.participantId) }.map(\.displayName)
    }

    var revealOutcome: RevealOutcome? {
        guard let round, round.phase == .revealed else { return nil }
        if round.isCancelled { return .cancelled }
        let mine = round.results?.first { $0.participantId == state?.you }
        return mine?.isCorrect == true ? .correct : .miss
    }

    // MARK: - Awards

    enum AwardKind: String { case fastest, onlyOne = "only_one", streak }

    struct AwardRow: Identifiable, Equatable {
        var id: String { kind.rawValue }
        let kind: AwardKind
        let name: String
        let color: String?
        let isYou: Bool
        /// fastest: seconds from the question appearing to the answer.
        var seconds: Double?
        /// fastest: the question it was on.
        var questionNumber: Int?
        /// only_one: questions nobody else knew; streak: right answers in a row.
        var count: Int?
    }

    /// The awards this build knows, for players still in the room.
    var awardRows: [AwardRow] {
        (state?.awards ?? []).compactMap { award in
            guard let kind = AwardKind(rawValue: award.kind),
                  let player = players.first(where: { $0.participantId == award.participantId })
            else { return nil }
            return AwardRow(
                kind: kind,
                name: player.displayName,
                color: player.color,
                isYou: player.participantId == state?.you,
                seconds: award.ms.map { Double($0) / 1000 },
                questionNumber: award.questionNumber,
                count: award.count
            )
        }
    }

    // MARK: - The end

    /// The host starts another game with everyone, unless the questions ran out.
    var canPlayAgain: Bool {
        isHost && state?.status == .finished && state?.finishedReason != "usage_limit" && hostName != nil
    }

    /// #240.9: the room moves to a new session with everyone in it; every
    /// phone, polling the same room, lands in the new lobby. On failure the
    /// ranking stays with an error, and Done still closes.
    func playAgain() async {
        guard canPlayAgain, !isWorking, let old = created, let name = hostName else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let room = try await createRoom(hostName: name, moving: old.roomId)
            guard !hasLeft else {
                // Closed while it was on its way: nobody waits in a lobby without a host.
                try? await network.endSession(sessionId: room.sessionId)
                return
            }
            reportClose(.finished)
            closeReported = false
            moveToRoom(room)
            await refresh()
            startPolling()
        } catch {
            guard !hasLeft else { return }
            Logger.network.error("Room play again failed: \(error, privacy: .public)")
            errorMessage = Self.genericMessage
        }
    }

    /// The share sheet opened on the final ranking.
    func rankingShared() {
        analytics.track(.roomRankingShared(role: isHost ? "host" : "guest", players: players.count))
    }

    /// Host only, once per game: how it ended (`room_closed`).
    func reportClose(_ reason: RoomCloseReason) {
        guard role == .host, created != nil, !closeReported else { return }
        closeReported = true
        analytics.track(.roomClosed(reason: reason, players: players.count, questions: round?.number ?? 0))
    }
}
