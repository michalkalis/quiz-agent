//
//  SilenceDetectionService+VAD.swift
//  Hangs
//
//  #185 track A (car test 2026-09-23): the speech state machine behind
//  auto-stop, fed by TWO detectors — the band-limited `EnergyVAD` on every tap
//  buffer, and Apple's SpeechDetector when it is paired
//  (`VADTuning.commandGateSensitivity`). Speech is active while EITHER says so.
//
//  What changed against the car test:
//  • The SpeechDetector alone never reported speech (16/16 recordings ended on
//    the 5 s window), so the energy detector is now the signal.
//  • Silence after speech was only re-checked when a detector event arrived;
//    a clock-driven check now fires at the hangover deadline regardless.
//  • Every answer recording starts from a clean slate (`beginAnswerDetection`)
//    and reports what the detectors saw (`endAnswerDetection`).
//

@preconcurrency import AVFoundation
import Clocks
import Foundation
import os

/// One answer recording's detection bookkeeping (`beginAnswerDetection`).
struct AnswerDetectionSession {
    let minSpeechDuration: TimeInterval
    let startedAt: AnyClock<Duration>.Instant
    var speechDetectorResults = 0
    var energyHeardSpeech = false
    var speechDetectorHeardSpeech = false
    var levelBuffers = 0
    var speechSecs: TimeInterval = 0
}

extension SilenceDetectionService {
    // MARK: - Detector inputs

    /// One tap buffer's level (drained on the main actor from the tap).
    func handleInputLevel(_ sample: InputLevelSample) {
        lastLevelAt = clock.now
        let wasSpeaking = energySpeaking || speechDetectorSpeaking
        energySpeaking = energyVAD.process(sample)
        inputLevelChannel.yield(InputLevel(db: sample.db, noiseFloorDb: energyVAD.noiseFloorDb))
        if var session = answerSession {
            session.levelBuffers += 1
            if energySpeaking { session.energyHeardSpeech = true }
            if energySpeaking || speechDetectorSpeaking { session.speechSecs += sample.duration }
            answerSession = session
        }
        applyCombinedSpeech(wasSpeaking: wasSpeaking)
    }

    /// One result from Apple's SpeechDetector (only when paired). Apple
    /// documents these as VAD-model errors only; counted per recording so a
    /// device test can see it, and a `speechDetected` result — should an iOS
    /// update ever deliver one — counts as speech.
    func handleSpeechDetectorResult(speechDetected: Bool) {
        let wasSpeaking = energySpeaking || speechDetectorSpeaking
        speechDetectorSpeaking = speechDetected
        if var session = answerSession {
            session.speechDetectorResults += 1
            if speechDetected { session.speechDetectorHeardSpeech = true }
            answerSession = session
        }
        applyCombinedSpeech(wasSpeaking: wasSpeaking)
    }

    // MARK: - State machine

    /// Move the state machine on the combined opinion. Idempotent: called on
    /// every detector input, it only acts on a change (plus the per-event
    /// silence re-check the clock-driven check backs up).
    private func applyCombinedSpeech(wasSpeaking: Bool) {
        let speaking = energySpeaking || speechDetectorSpeaking
        guard speaking else {
            switch state {
            case let .speechActive(speechStart):
                let now = clock.now
                state = .silenceAccumulating(speechStart: speechStart, since: now)
                scheduleSilenceCheck(since: now)
                Logger.voice.debug("🔇 Silence detection: silence started after speech")
            case .silenceAccumulating:
                evaluateSilence()
            case .idle:
                break
            }
            return
        }

        // Barge-in: only when TTS is playing on an external audio route (echo
        // from the device speaker would trigger false positives). Fired on the
        // rising edge only — the energy detector reports every buffer.
        if isTTSPlaybackActive && isExternalAudioRoute() {
            if !wasSpeaking {
                bargeInChannel.yield(())
                Logger.voice.info("🗣️ Barge-in: speech detected during TTS on external route")
            }
            return
        }

        switch state {
        case .idle:
            state = .speechActive(since: clock.now)
            // Anchor the first-hypothesis latency clock (#120): measured from
            // VAD speech-start to the first transcriber result.
            pendingFirstHypothesisSince = clock.now
            silenceChannel.yield(.speechStarted)
            Logger.voice.debug("🔇 Silence detection: speech started")
            // Sentry only inside an answer recording: the energy detector also
            // runs through every command window, where this would be a flood.
            if let session = answerSession {
                SentryLog.info("vad speech began", category: .voice, attributes: [
                    "source": speechSourceTag,
                    "atMs": Self.milliseconds(session.startedAt.duration(to: clock.now)),
                ])
            }
        case let .silenceAccumulating(speechStart, _):
            // Resume the SAME utterance — keep its original start so a brief
            // mid-utterance pause doesn't reset the speech-duration clock.
            state = .speechActive(since: speechStart)
            cancelSilenceCheck()
            Logger.voice.debug("🔇 Silence detection: speech resumed")
        case .speechActive:
            break
        }
    }

    /// Stop / keep waiting / drop a blip, once silence has accumulated. Reached
    /// from the clock-driven check at the hangover deadline and from any
    /// detector input in between.
    func evaluateSilence() {
        guard case let .silenceAccumulating(speechStart, since) = state else { return }
        let silenceElapsed = since.duration(to: clock.now).timeInterval
        let speechDuration = speechStart.duration(to: since).timeInterval
        let minSpeech = answerSession?.minSpeechDuration ?? VADTuning.minSpeechDurationSecs
        switch SilenceStopDecision.evaluate(
            speechDuration: speechDuration, silenceElapsed: silenceElapsed, minSpeechDuration: minSpeech
        ) {
        case .wait:
            break
        case .stop:
            cancelSilenceCheck()
            state = .idle
            silenceChannel.yield(.silenceAfterSpeech(duration: silenceElapsed))
            if answerSession != nil {
                SentryLog.info("vad speech ended", category: .voice, attributes: ["speechSecs": speechDuration])
            }
            Logger.voice.debug("🔇 Silence detection: threshold reached (\(String(format: "%.1f", silenceElapsed), privacy: .public)s)")
        case .rejectBlip:
            // Utterance too short (cough/blip/mic-pop) — drop it silently.
            cancelSilenceCheck()
            state = .idle
            Logger.voice.debug("🔇 Silence detection: rejected blip (\(String(format: "%.2f", speechDuration), privacy: .public)s speech)")
        }
    }

    /// Re-check the silence at `since + hangover` on the injected clock, so the
    /// stop never waits for a detector event that may not come.
    private func scheduleSilenceCheck(since: AnyClock<Duration>.Instant) {
        cancelSilenceCheck()
        let deadline = since.advanced(by: .milliseconds(Int((VADTuning.silenceHangoverSecs * 1000).rounded())))
        let clock = clock
        silenceCheckTask = Task { [weak self] in
            try? await clock.sleep(until: deadline, tolerance: nil)
            guard !Task.isCancelled else { return }
            self?.evaluateSilence()
        }
    }

    private func cancelSilenceCheck() {
        silenceCheckTask?.cancel()
        silenceCheckTask = nil
    }

    /// Back to a clean slate: no speech, no pending silence check, a fresh
    /// noise floor. Every listening window and every answer recording starts
    /// here (#185 H3 — a state left over from the command window must never
    /// decide an answer).
    func resetSpeechDetection() {
        cancelSilenceCheck()
        state = .idle
        energyVAD = EnergyVAD()
        energySpeaking = false
        speechDetectorSpeaking = false
        lastLevelAt = nil
        pendingFirstHypothesisSince = nil
    }

    // MARK: - Answer detection session

    func beginAnswerDetection(minSpeechDuration: TimeInterval) {
        resetSpeechDetection()
        answerSession = AnswerDetectionSession(minSpeechDuration: minSpeechDuration, startedAt: clock.now)
    }

    func endAnswerDetection() -> AnswerDetectionReport {
        defer { answerSession = nil }
        guard let session = answerSession else { return .empty }
        return AnswerDetectionReport(
            energyHeardSpeech: session.energyHeardSpeech,
            speechDetectorHeardSpeech: session.speechDetectorHeardSpeech,
            speechDetectorResults: speechDetectorPaired ? session.speechDetectorResults : nil,
            levelBuffers: session.levelBuffers,
            noiseFloorDb: energyVAD.noiseFloorDb,
            peakDb: energyVAD.peakDb,
            speechMs: Int((session.speechSecs * 1000).rounded()),
            ambiguousMs: Int((energyVAD.ambiguousSecs * 1000).rounded()),
            minSpeechMs: Int((session.minSpeechDuration * 1000).rounded())
        )
    }

    var noSpeechWindowVerdict: NoSpeechWindowVerdict {
        guard let session = answerSession else { return .noAudio }
        if session.energyHeardSpeech || session.speechDetectorHeardSpeech { return .speechHeard }
        let staleAfter = Duration.milliseconds(Int((VADTuning.levelStaleAfterSecs * 1000).rounded()))
        guard let lastLevelAt, lastLevelAt.duration(to: clock.now) <= staleAfter else { return .noAudio }
        guard let floor = energyVAD.noiseFloorDb else { return .calibrating }
        guard floor > VADTuning.digitalSilenceDbfs else { return .noAudio }
        guard energyVAD.ambiguousSecs < VADTuning.ambiguousActivityMaxSecs else { return .possibleSpeech }
        return .quiet
    }

    // MARK: - Helpers

    /// Consume the pending first-hypothesis latency anchor: milliseconds from
    /// VAD speech-start to now, or `nil` when no utterance is pending (already
    /// consumed, or the transcript preceded any VAD transition). One-shot per
    /// utterance — the metric means "how long until the engine said ANYTHING".
    func consumeFirstHypothesisLatencyMs() -> Int? {
        guard let since = pendingFirstHypothesisSince else { return nil }
        pendingFirstHypothesisSince = nil
        return Self.milliseconds(since.duration(to: clock.now))
    }

    private var speechSourceTag: String {
        switch (energySpeaking, speechDetectorSpeaking) {
        case (true, true): "both"
        case (false, true): "speechDetector"
        default: "energy"
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int((duration.timeInterval * 1000).rounded())
    }

    private func isExternalAudioRoute() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let externalPorts: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .carAudio, .airPlay, .headphones, .headsetMic,
        ]
        return outputs.contains { externalPorts.contains($0.portType) }
    }
}
