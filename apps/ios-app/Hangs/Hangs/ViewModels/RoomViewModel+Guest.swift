//
//  RoomViewModel+Guest.swift
//  Hangs
//
//  #230.2: a guest who joined from another city has no host in the room to
//  listen to, so their own phone reads each question aloud (from the room's
//  audio). It is switched on by default after a link join, and for this game only.
//

import Foundation
import os

extension RoomViewModel {
    /// The guest's speaker button. Off stops the clip now; on reads the
    /// open question if this phone has not read it yet.
    func setGuestReadsAloud(_ on: Bool) async {
        guard role == .guest, on != guestReadsAloud else { return }
        guestReadsAloud = on
        if let invite { analytics.track(.roomGuestReadAloud(on: on, via: invite.via)) }
        if on, let state { guestReact(to: state) }
        if !on {
            guestReadTask?.cancel()
            await audio.stopPlayback()
        }
    }

    func guestReact(to state: RoomState) {
        guard guestReadsAloud, state.status == .playing, let round = state.round,
              round.phase == .reading || round.phase == .answering,
              guestReadQuestionId != round.questionId
        else { return }
        guestReadQuestionId = round.questionId
        guestReadTask?.cancel()
        guestReadTask = Task { await guestRead(roomId: state.roomId, questionId: round.questionId) }
    }

    private func guestRead(roomId: String, questionId: String) async {
        do {
            // Playback only and mixable: never interrupts a call or music that is already running.
            try audio.setupPlaybackOnlySession()
            let data = try await network.downloadAudio(
                from: "/api/v1/rooms/\(roomId)/question/audio?question_id=\(questionId)"
            )
            // Switched off while the audio was downloading.
            guard guestReadsAloud, !Task.isCancelled else { return }
            _ = try await audio.playOpusAudio(data)
        } catch is CancellationError {
        } catch {
            Logger.audio.warning("Guest read-aloud failed: \(error, privacy: .public)")
        }
    }
}
