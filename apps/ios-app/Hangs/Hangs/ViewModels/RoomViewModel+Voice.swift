//
//  RoomViewModel+Voice.swift
//  Hangs
//
//  #249.5 (founder 2026-11-26): every player answers a typed-answer question
//  by voice, with solo's controls and solo's server transcription. Like solo
//  (`RecordingCoordinator+Capture`), the shared mic engine records and its VAD
//  ends the recording: silence after speech sends it, and nothing said within
//  solo's 5 s start window (when the detector can vouch) ends it unsent. Stop,
//  or the end of the answer time, sends it too. One clip, one upload to the
//  room's voice endpoint, which transcribes it and stores it like a typed answer.
//  Typing stays one tap away, and is the way to answer when the mic is refused.
//

import Foundation
import os

extension RoomViewModel {
    enum VoicePhase: Equatable {
        case idle
        /// Answer was tapped: the mic prompt, the session and the engine are
        /// coming up. A second tap must not start a second recording.
        case starting
        case recording
        /// The clip is with the server, being transcribed.
        case sending
    }

    enum VoiceNote: Equatable {
        /// Nothing usable was heard (silence, noise): solo's "Didn't catch that".
        case didNotCatch
        /// The upload failed (offline, server error); the player may try again or type.
        case notSent
        /// The server refused voice for now (a limit, 429): a retry cannot work, so type.
        case typeInstead
    }

    /// Less audio than this is a tap on Stop, not an answer.
    static let minVoiceSeconds = 0.3

    /// The open question takes a spoken answer now. Options are tapped, and
    /// the host's phone does not cut its own read for the room.
    var canSpeak: Bool { voicePhase != .starting && voiceAnswerOpen }

    private var voiceAnswerOpen: Bool {
        canAnswer && question?.isMultipleChoice == false && !(isHost && isReadingAloud)
    }

    /// Answer opens typing instead of the mic: the mic is refused, or the
    /// server refused voice for this question (`VoiceNote.typeInstead`).
    var answersByTyping: Bool { micDenied || voiceUnavailable }

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
        case .idle, .starting: break
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
        case .starting, .sending: break
        }
    }

    func startRecording() async {
        guard voicePhase == .idle, canSpeak, let questionId = round?.questionId else { return }
        // Set before the first await: a second tap during the prompt or the
        // engine start is ignored (`toggleRecording`, `canSpeak`).
        voicePhase = .starting
        guard await audio.requestMicrophonePermission() else {
            voicePhase = .idle
            micRefused = true
            return
        }
        voiceNote = nil
        voiceHeardSpeech = false
        voicePCM.withLock { $0 = Data() }
        // A guest's own read of the question stops, as a solo tap on Answer does.
        if role == .guest { guestReadTask?.cancel() }
        do {
            try audio.ensureRecordingSession()
            await audio.prepareForRecording()
            let engine = await startEngine()
            // The time may have run out or the answer locked during the prompt and the settle.
            guard voiceAnswerOpen, round?.questionId == questionId, voicePhase == .starting else {
                if voicePhase == .starting { voicePhase = .idle }
                releaseEngine()
                return
            }
            let pcm = voicePCM
            if let engine {
                voiceUsesEngine = true
                voiceSampleRate = Int(engine.answerAudioSampleRate)
                engine.setAnswerAudioSink { chunk in pcm.withLock { $0.append(chunk) } }
            } else {
                // No engine (previews, a failed recognizer setup): the plain stream, no auto-stop.
                voiceUsesEngine = false
                voiceSampleRate = 16000
                try await audio.startStreamingRecording { chunk in pcm.withLock { $0.append(chunk) } }
            }
            voiceQuestionId = questionId
            voicePhase = .recording
            if let engine { armSilenceDetection(engine, questionId: questionId) }
        } catch {
            audio.stopStreamingRecording()
            releaseEngine()
            voicePhase = .idle
            voiceNote = .notSent
            Logger.audio.warning("Room recording failed to start: \(error, privacy: .public)")
        }
    }

    /// Solo's engine handshake: adopt a running engine (or one starting, for a
    /// bounded wait), else start it and remember to stop it afterwards.
    private func startEngine() async -> SilenceDetectionServiceProtocol? {
        guard let silence else { return nil }
        if !silence.isListening, !silence.isStartingListening {
            startedVoiceListener = true
            await silence.startListening()
        } else if silence.isStartingListening {
            var waitedMs = 0
            while silence.isStartingListening, waitedMs < VoiceCommandCoordinator.listenerSettleBudgetMs {
                do { try await clock.sleep(for: .milliseconds(100)) } catch { break }
                waitedMs += 100
            }
        }
        guard silence.isListening else {
            releaseEngine()
            return nil
        }
        return silence
    }

    private func releaseEngine() {
        guard startedVoiceListener else { return }
        startedVoiceListener = false
        silence?.stopListening()
    }

    /// Solo's two silence rules, with solo's thresholds: the VAD's silence after
    /// speech sends the answer; no speech within `Config.speechStartWindow` ends
    /// the recording unsent, but only when the detector can vouch for the silence.
    private func armSilenceDetection(_ engine: SilenceDetectionServiceProtocol, questionId: String) {
        engine.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        let events = engine.makeSilenceEventStream()
        voiceTasks.append(Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled, self.isRecording(questionId) else { return }
                switch event {
                case .speechStarted:
                    self.voiceHeardSpeech = true
                case .silenceAfterSpeech:
                    // Its own task: sending tears this consumer down.
                    Task { await self.stopRecordingAndSend() }
                    return
                }
            }
        })
        voiceTasks.append(Task { [weak self] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(for: .seconds(Config.speechStartWindow)) } catch { return }
            guard let self, self.isRecording(questionId), !self.voiceHeardSpeech,
                  engine.noSpeechWindowVerdict.mayEndRecording
            else { return }
            _ = self.takeRecording()
            self.voiceNote = .didNotCatch
        })
    }

    private func isRecording(_ questionId: String) -> Bool {
        voicePhase == .recording && voiceQuestionId == questionId
    }

    /// Stop the mic and send what was recorded, once. Silence never reaches
    /// the server; a failure leaves the question open for another try or typing.
    func stopRecordingAndSend() async {
        guard voicePhase == .recording, let questionId = voiceQuestionId else { return }
        let pcm = takeRecording()
        guard Double(pcm.count) >= Self.minVoiceSeconds * Double(voiceSampleRate * 2) else {
            voiceNote = .didNotCatch
            return
        }
        guard let roomId = state?.roomId, round?.questionId == questionId, !hasLeft else { return }
        voicePhase = .sending
        defer { voicePhase = .idle }
        do {
            try apply(await rooms.answerByVoice(
                roomId: roomId, questionId: questionId, audioWAV: WavEncoder.wrapPCM16(pcm, sampleRate: voiceSampleRate)
            ))
        } catch NetworkError.answerNotCaptured {
            voiceNote = .didNotCatch
        } catch NetworkError.quotaLimitReached, NetworkError.voiceLimitReached,
            NetworkError.serverError(statusCode: 429, _)
        {
            // A limit, not a hiccup: "try again" cannot work, typing still does.
            voiceUnavailable = true
            voiceNote = .typeInstead
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
        voiceTasks.forEach { $0.cancel() }
        voiceTasks = []
        if voiceUsesEngine, let silence {
            silence.setAnswerAudioSink(nil)
            _ = silence.endAnswerDetection()
            releaseEngine()
        } else {
            audio.stopStreamingRecording()
        }
        voicePhase = .idle
        voiceQuestionId = nil
        return voicePCM.withLock { data in
            defer { data = Data() }
            return data
        }
    }
}
