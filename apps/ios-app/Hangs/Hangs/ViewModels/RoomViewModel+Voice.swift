//
//  RoomViewModel+Voice.swift
//  Hangs
//
//  #249.5 (founder 2026-11-26): every player answers a typed-answer question
//  by voice, with solo's controls and solo's server transcription. The mic
//  records 16 kHz PCM on the shared `AudioService` (as `TextDictation` does);
//  Stop, or the end of the answer time, sends the clip once to the room's
//  voice endpoint, which transcribes it and stores it like a typed answer.
//  Typing stays one tap away, and is the way to answer when the mic is refused.
//

import Foundation
import os

extension RoomViewModel {
    enum VoicePhase: Equatable {
        case idle
        case recording
        /// The clip is with the server, being transcribed.
        case sending
    }

    enum VoiceNote: Equatable {
        /// Nothing usable was heard (silence, noise): solo's "Didn't catch that".
        case didNotCatch
        /// The upload failed (offline, server error); the player may try again or type.
        case notSent
    }

    /// Less than this much audio is a tap on Stop, not an answer (0.3 s of 16 kHz PCM16).
    static let minVoiceBytes = 9600

    /// The open question takes a spoken answer now. Options are tapped, and
    /// the host's phone does not cut its own read for the room.
    var canSpeak: Bool {
        canAnswer && question?.isMultipleChoice == false && !(isHost && isReadingAloud)
    }

    /// The mic is refused (this game or in iOS Settings): Answer opens typing.
    var micDenied: Bool { micRefused || audio.microphonePermissionStatus == .denied }

    /// The bar under the question, in solo's states (`QuestionListenBar`):
    /// reading, the answer time draining, the open mic, the answer on its way.
    /// None once this player's answer is in or the time is up (the footer says so).
    var listenPhase: QuestionListenPhase? {
        guard let round, round.yourAnswer == nil, !isGrading else { return nil }
        switch voicePhase {
        case .recording: return .listening(.open)
        case .sending: return .evaluating
        case .idle: break
        }
        if submittingAnswer != nil { return .evaluating }
        if round.phase == .reading { return .readingQuestion }
        guard round.phase == .answering, let left = secondsLeft(), left > 0 else { return nil }
        return .thinking(remaining: left, total: max(left, answerWindowSeconds ?? left))
    }

    /// Solo's Answer / Stop.
    func toggleRecording() async {
        switch voicePhase {
        case .idle: await startRecording()
        case .recording: await stopRecordingAndSend()
        case .sending: break
        }
    }

    func startRecording() async {
        guard voicePhase == .idle, canSpeak, let questionId = round?.questionId else { return }
        guard await audio.requestMicrophonePermission() else {
            micRefused = true
            return
        }
        voiceNote = nil
        voicePCM.withLock { $0 = Data() }
        // A guest's own read of the question stops, as a solo tap on Answer does.
        if role == .guest { guestReadTask?.cancel() }
        do {
            try audio.ensureRecordingSession()
            await audio.prepareForRecording()
            // The time may have run out or the answer locked during the prompt and the settle.
            guard canSpeak, round?.questionId == questionId else { return }
            let pcm = voicePCM
            try await audio.startStreamingRecording { chunk in
                pcm.withLock { $0.append(chunk) }
            }
            voiceQuestionId = questionId
            voicePhase = .recording
        } catch {
            audio.stopStreamingRecording()
            voiceNote = .notSent
            Logger.audio.warning("Room recording failed to start: \(error, privacy: .public)")
        }
    }

    /// Stop the mic and send what was recorded, once. Silence never reaches
    /// the server; a failure leaves the question open for another try or typing.
    func stopRecordingAndSend() async {
        guard voicePhase == .recording, let questionId = voiceQuestionId else { return }
        let pcm = takeRecording()
        guard pcm.count >= Self.minVoiceBytes else {
            voiceNote = .didNotCatch
            return
        }
        guard let roomId = state?.roomId, round?.questionId == questionId, !hasLeft else { return }
        voicePhase = .sending
        defer { voicePhase = .idle }
        do {
            try apply(await rooms.answerByVoice(
                roomId: roomId, questionId: questionId, audioWAV: WavEncoder.wrapPCM16(pcm)
            ))
        } catch NetworkError.answerNotCaptured {
            voiceNote = .didNotCatch
        } catch NetworkError.serverError(statusCode: 409, _) {
            // Answered on another try, or the time ran out: the room knows.
            await refresh()
        } catch is CancellationError {
        } catch {
            voiceNote = .notSent
            Logger.network.warning("Room voice answer failed: \(error, privacy: .public)")
        }
    }

    /// Leaving the game drops a recording in progress without sending it.
    func cancelRecording() {
        guard voicePhase == .recording else { return }
        _ = takeRecording()
    }

    private func takeRecording() -> Data {
        audio.stopStreamingRecording()
        voicePhase = .idle
        voiceQuestionId = nil
        return voicePCM.withLock { data in
            defer { data = Data() }
            return data
        }
    }
}
