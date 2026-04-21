//
//  QuizViewModel+Audio.swift
//  Hangs
//
//  Audio playback, silence-detection listening, barge-in, device management.
//

import Foundation
import os

// MARK: - Audio Playback & Silence Detection

extension QuizViewModel {

    /// Start listening for silence events and barge-in during question playback.
    /// Safe to call multiple times (the service itself no-ops if already listening).
    func startSilenceDetectionListening() async {
        guard let service = silenceDetectionService else { return }

        await service.startListening()

        // Barge-in: if the user starts speaking during TTS on an external audio
        // route, stop playback and kick off recording immediately.
        bargeInTask?.cancel()
        bargeInTask = Task { [weak self] in
            for await _ in service.bargeInEvents {
                guard let self, !Task.isCancelled else { break }
                await self.handleBargeIn()
            }
        }
    }

    /// Stop silence-detection listening and tear down the barge-in subscription.
    func stopSilenceDetectionListening() {
        bargeInTask?.cancel()
        bargeInTask = nil
        silenceDetectionService?.stopListening()
    }

    /// Handle barge-in: user spoke during TTS playback on external audio route.
    private func handleBargeIn() async {
        guard quizState == .askingQuestion else { return }

        Logger.voice.info("🗣️ Barge-in triggered — stopping TTS and starting recording")

        // 1. Stop TTS immediately
        await stopAnyPlayingAudio()

        // 2. Clear barge-in activation so a re-fire isn't triggered by the
        //    teardown tail of TTS audio.
        silenceDetectionService?.setTTSPlaybackActive(false)

        // 3. Wait for audio hardware to settle
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 4. Guard again — state may have changed during sleep
        guard quizState == .askingQuestion else { return }

        // 5. Auto-start recording (same as post-TTS flow)
        cancelAnswerTimer()
        isAutoRecording = true
        await startRecording()
    }

    /// Play question TTS audio, then resume silence-detection listening and start recording/timer.
    func playQuestionAudio(from urlString: String) async {
        // Store URL for re-playing on demand
        currentQuestionAudioUrl = urlString

        // Mute guard: skip TTS but still start silence detection + timer/recording
        guard !settings.isMuted else {
            await startSilenceDetectionListening()
            guard quizState == .askingQuestion else { return }
            guard currentQuestion?.isMultipleChoice != true else { return }

            if settings.autoRecordEnabled && silenceDetectionService != nil && !isRerecording {
                startThinkingTimeCountdown()
            } else {
                startAnswerTimer()
            }
            return
        }

        // Stop silence detection before TTS to avoid AVAudioEngine + AVPlayer conflict
        // (SpeechAnalyzer's RealtimeMessenger crashes when both run simultaneously).
        stopSilenceDetectionListening()

        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            _ = try await audioService.playOpusAudio(audioData)
        } catch {
            Logger.audio.warning("⚠️ Failed to play question audio: \(error, privacy: .public)")
            // Don't fail the quiz if audio doesn't play
        }

        // Restart silence detection after TTS finishes
        await startSilenceDetectionListening()

        // After TTS finishes (or was interrupted by barge-in), choose next path
        guard quizState == .askingQuestion else { return }
        // MCQ questions use tap selection, not recording
        guard currentQuestion?.isMultipleChoice != true else { return }

        if settings.autoRecordEnabled && silenceDetectionService != nil && !isRerecording {
            // Auto-record path: thinking time countdown → auto-start recording
            startThinkingTimeCountdown()
        } else {
            // Legacy path: countdown timer → fixed duration recording
            startAnswerTimer()
        }
    }

    /// Play feedback audio from URL, returning the playback duration
    func playFeedbackAudio(from urlString: String) async -> TimeInterval {
        do {
            let audioData = try await networkService.downloadAudio(from: urlString)
            let duration = try await audioService.playOpusAudio(audioData)
            return duration
        } catch {
            Logger.audio.warning("⚠️ Failed to play feedback audio: \(error, privacy: .public)")
            return 3.0  // Default fallback duration
        }
    }

    /// Play feedback audio from base64 string, returning the playback duration
    func playFeedbackAudioBase64(_ base64: String) async -> TimeInterval {
        do {
            let duration = try await audioService.playOpusAudioFromBase64(base64)
            return duration
        } catch {
            Logger.audio.warning("⚠️ Failed to play base64 feedback audio: \(error, privacy: .public)")
            return 3.0  // Default fallback duration
        }
    }

    /// Stop any currently playing audio (cleanup during state transitions)
    func stopAnyPlayingAudio() async {
        await audioService.stopPlayback()

        Logger.audio.debug("🔇 Stopped any playing audio for state transition")
    }

    // MARK: - Audio Device Management

    /// Toggle audio mode between Call Mode and Media Mode
    func toggleAudioMode() {
        Task {
            let newMode = selectedAudioMode.id == "call"
                ? (AudioMode.forId("media") ?? AudioMode.default)
                : (AudioMode.forId("call") ?? AudioMode.default)

            do {
                try await audioService.switchAudioMode(newMode)
                settings.audioMode = newMode.id

                Logger.audio.info("🔄 Switched to \(newMode.name, privacy: .public)")
            } catch {
                errorMessage = "Failed to switch audio mode: \(error.localizedDescription)"

                Logger.audio.error("❌ Error switching audio mode: \(error, privacy: .public)")
            }
        }
    }

    /// Refresh available audio input devices
    func refreshAudioDevices() {
        audioService.refreshAvailableDevices()

        // Try to restore saved preferred device
        if let savedId = settings.preferredInputDeviceId {
            // Check if saved device is still available
            if let device = availableInputDevices.first(where: { $0.id == savedId }) {
                do {
                    try audioService.setPreferredInputDevice(device)
                    Logger.audio.info("🎤 Restored preferred input device: \(device.name, privacy: .public)")
                } catch {
                    Logger.audio.warning("⚠️ Failed to restore preferred input device: \(error, privacy: .public)")
                }
            } else {
                // Saved device not available, keep preference for reconnection
                Logger.audio.info("🎤 Saved input device not available, using automatic")
            }
        }
    }

    /// Set preferred input device
    /// - Parameter device: Device to use, or nil for automatic selection
    func setPreferredInputDevice(_ device: AudioDevice?) {
        do {
            try audioService.setPreferredInputDevice(device)

            // Persist preference (auto-persisted via $settings sink)
            settings.preferredInputDeviceId = device?.id

            Logger.audio.info("🎤 Set preferred input device: \(device?.name ?? "Automatic", privacy: .public)")
        } catch {
            errorMessage = "Failed to set audio device: \(error.localizedDescription)"

            Logger.audio.error("❌ Error setting preferred input device: \(error, privacy: .public)")
        }
    }
}
