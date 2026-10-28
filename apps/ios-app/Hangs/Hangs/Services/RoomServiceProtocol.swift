//
//  RoomServiceProtocol.swift
//  Hangs
//
//  #212: the same-room multiplayer endpoints (`/api/v1/rooms`). The host
//  still creates and starts its session through `NetworkServiceProtocol`.
//

import Foundation

protocol RoomServiceProtocol: Sendable {
    /// Makes the host's idle session a room. `thinkingSeconds` 3–60.
    func createRoom(sessionId: String, hostName: String, revealMode: RoomState.RevealMode, thinkingSeconds: Int) async throws -> RoomCreated
    /// Games waiting to start on the caller's Wi-Fi.
    func nearbyRooms() async throws -> [NearbyRoom]
    /// Joins (or, already in, renames in the lobby) and returns the full state.
    func joinRoom(_ invite: RoomInvite, displayName: String) async throws -> RoomState
    /// The host removes a guest, or a guest leaves (their own id).
    func removePlayer(roomId: String, participantId: String) async throws
    /// `since` = the last version seen; unchanged → `changed == false`.
    func roomState(roomId: String, since: Int?) async throws -> RoomState
    /// Host: the question was read aloud, the answer time starts.
    func openQuestion(roomId: String, questionId: String) async throws -> RoomState
    /// An option key (a–d) or typed text; final once sent.
    func answer(roomId: String, questionId: String, answer: String) async throws -> RoomState
    /// The app went to the background during the question (never during a call).
    func reportAway(roomId: String, questionId: String) async throws
    /// Host: the next question for everyone, or the final ranking.
    func nextQuestion(roomId: String) async throws -> RoomState
}
