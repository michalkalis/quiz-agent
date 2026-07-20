//
//  AudioDeviceState+Playback.swift
//  Hangs
//
//  TTS/feedback playback + mute — the isPlayingQuestionTTS writers (#113 T2).
//  The flag itself stays façade-resident (decision 4); this file writes it
//  only through the injected get/set closures.
//

import Foundation
import os

// MARK: - Audio Playback

extension AudioDeviceState {
    /// Play question TTS audio, then resume silence-detection listening and start recording/timer.
    func playQuestionAudio(from urlString: String) async {
        // Store URL for re-playing on demand
        setCurrentQuestionAudioUrl(urlString)

        // Mute guard: skip TTS but still start silence detection + timer/recording
        guard !settings().isMuted else {
            await startSilenceDetectionListening()
            guard isAskingQuestion() else { return }

            if settings().autoRecordEnabled, !isRerecording() {
                startThinkingTimeCountdown()
            } else {
                startAnswerTimer()
            }
            return
        }

        // Stop silence detection before TTS to avoid AVAudioEngine + AVPlayer conflict
        // (SpeechAnalyzer's RealtimeMessenger crashes when both run simultaneously).
        // isPlayingQuestionTTS closes the command window for the duration (77.5).
        setPlayingQuestionTTS(true)
        stopSilenceDetectionListening()

        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            _ = try await audioService.playOpusAudio(audioData)
        } catch {
            Logger.audio.warning("⚠️ Failed to play question audio: \(error, privacy: .public)")
            // Don't fail the quiz if audio doesn't play — but fail loud to Sentry.
            Self.reportAudioFailure(error, kind: "question")
        }

        // Restart silence detection (+ command listener) after TTS finishes.
        setPlayingQuestionTTS(false)
        await startSilenceDetectionListening()

        // After TTS finishes (or was interrupted by barge-in), choose next path
        guard isAskingQuestion() else { return }

        if settings().autoRecordEnabled, !isRerecording() {
            // Auto-record path: thinking time countdown → auto-start recording
            startThinkingTimeCountdown()
        } else {
            // Legacy path: countdown timer → fixed duration recording
            startAnswerTimer()
        }
    }

    /// Whether the on-demand "replay question" control can actually do something:
    /// audio is not muted AND a question audio URL is known. The replay button must
    /// track this capability (`.disabled(!canReplayAudio)`) rather than look interactive
    /// while silently no-opping when the backend supplied no question audio (#59.5).
    var canReplayAudio: Bool {
        !settings().isMuted && currentQuestionAudioUrl() != nil
    }

    /// Replay/restart the current question's TTS on demand WITHOUT re-arming the
    /// think/answer countdown or auto-record (Decision 2 of the voice-answer
    /// screen fix). Unlike `playQuestionAudio(from:)`, this plays audio only —
    /// it never calls `startThinkingTimeCountdown()` / `startAnswerTimer()`, so
    /// a running countdown is left untouched and no new one is armed. Harmless
    /// no-op when muted (no audio to replay) or when no question URL is known.
    ///
    /// Tap-anywhere-on-question (founder, 2026-07-11): a tap DURING question TTS
    /// (the initial read or an earlier replay) restarts playback from the top.
    /// `isPlayingQuestionTTS` flags the in-flight TTS to stop; the playback run
    /// is registered in the task bag so a newer tap cancels the older run before
    /// stopping its audio — otherwise the interrupted run's tail would clear the
    /// flag and re-arm the SpeechAnalyzer engine while the new AVPlayer playback
    /// is still going (the engine + player conflict documented above).
    func replayQuestionAudio() async {
        guard !settings().isMuted, let urlString = currentQuestionAudioUrl() else { return }

        // Re-entrancy: neutralise any previous replay run FIRST so its tail
        // can't interleave with this one, then stop the in-flight TTS so this
        // tap restarts the question cleanly instead of layering playback.
        taskBag.cancel(.questionReplay)
        if isPlayingQuestionTTS() {
            await stopAnyPlayingAudio()
        }

        let run = Task { [weak self] in
            guard let self else { return }

            // Stop silence detection before TTS to avoid the AVAudioEngine + AVPlayer
            // conflict (SpeechAnalyzer's RealtimeMessenger crashes if both run).
            setPlayingQuestionTTS(true)
            stopSilenceDetectionListening()

            do {
                let audioData = try await networkService.downloadAudio(from: urlString)
                _ = try await audioService.playOpusAudio(audioData)
            } catch {
                Logger.audio.warning("⚠️ Failed to replay question audio: \(error, privacy: .public)")
                Self.reportAudioFailure(error, kind: "question-replay")
            }

            // Cancelled = a newer tap (or teardown) took over: it owns the
            // silence-detection restart, so only clear the flag — it must not
            // leak `true` past the run, but re-arming the engine here would
            // race the newer run's playback.
            guard !Task.isCancelled else {
                setPlayingQuestionTTS(false)
                return
            }

            // Restart silence detection (and barge-in) after TTS finishes — but
            // deliberately NO timer re-arming, unlike playQuestionAudio's tail.
            setPlayingQuestionTTS(false)
            await startSilenceDetectionListening()
        }
        taskBag.add(run, key: .questionReplay)
        await run.value
    }

    /// Play feedback audio from URL, returning the playback duration
    func playFeedbackAudio(from urlString: String) async -> TimeInterval {
        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            let duration = try await audioService.playOpusAudio(audioData)
            return duration
        } catch {
            Logger.audio.warning("⚠️ Failed to play feedback audio: \(error, privacy: .public)")
            Self.reportAudioFailure(error, kind: "feedback")
            return 3.0 // Default fallback duration
        }
    }

    /// Play feedback audio from base64 string, returning the playback duration
    func playFeedbackAudioBase64(_ base64: String) async -> TimeInterval {
        do {
            let duration = try await audioService.playOpusAudioFromBase64(base64)
            return duration
        } catch {
            Logger.audio.warning("⚠️ Failed to play base64 feedback audio: \(error, privacy: .public)")
            return 3.0 // Default fallback duration
        }
    }

    /// Toggle mute and make it take effect immediately: the `isMuted` guards in
    /// the play paths only gate *starting* playback, so muting mid-read must also
    /// stop the in-flight TTS (founder bug 2026-07-11). The interrupted play run's
    /// tail (silence-detection restart + timer arming) proceeds as after barge-in.
    func toggleMute() async {
        setMuted(!settings().isMuted)
        if settings().isMuted, isPlayingQuestionTTS() {
            await stopAnyPlayingAudio()
        }
    }

    /// Stop any currently playing audio (cleanup during state transitions)
    func stopAnyPlayingAudio() async {
        await audioService.stopPlayback()

        Logger.audio.debug("🔇 Stopped any playing audio for state transition")
    }
}
