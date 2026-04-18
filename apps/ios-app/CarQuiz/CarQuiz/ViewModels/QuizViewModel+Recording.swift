//
//  QuizViewModel+Recording.swift
//  CarQuiz
//
//  Recording lifecycle, STT streaming, answer submission, and confirmation
//

import Foundation
import os
import Sentry

// MARK: - Recording Lifecycle

extension QuizViewModel {

    /// Toggle recording: start if asking a question, stop and submit if recording
    func toggleRecording() async {
        switch quizState {
        case .askingQuestion:
            cancelAnswerTimer()
            cancelThinkingTime()
            await startRecording()
        case .recording:
            cancelAutoStopRecordingTimer()
            await stopRecordingAndSubmit()
        default:
            break
        }
    }

    /// Start recording the user's voice answer
    /// Handles audio preparation, state transitions, and error rollback
    /// Routes to streaming STT (ElevenLabs) or batch M4A (Whisper) based on feature flag
    func startRecording() async {
        cancelAnswerTimer()
        errorMessage = nil
        transition(to: .recording)
        voiceCommandService?.setRecordingActive(true)

        // Choose streaming STT or batch M4A based on feature flag
        if Config.useElevenLabsSTT && sttService != nil {
            await startStreamingRecording()
        } else {
            await startBatchRecording()
        }
    }

    /// Start batch M4A recording (original Whisper path)
    private func startBatchRecording() async {
        do {
            await audioService.prepareForRecording()
            try audioService.startRecording()

            if isAutoRecording, let service = voiceCommandService {
                speechDetectedDuringAutoRecord = false
                startSilenceDetection(service: service)
            }

            startAutoStopRecordingTimer()
        } catch {
            isAutoRecording = false
            speechDetectedDuringAutoRecord = false
            transition(to: .askingQuestion)
            errorMessage = "Recording failed: \(error.localizedDescription)"

            Logger.audio.error("❌ Recording failed to start: \(error, privacy: .public)")
        }
    }

    /// Start streaming recording with ElevenLabs Scribe v2 Realtime STT
    private func startStreamingRecording() async {
        guard let sttService else {
            // Fallback to batch if STT service unavailable
            await startBatchRecording()
            return
        }

        do {
            // 1. Get single-use token from backend
            let token = try await networkService.fetchElevenLabsToken()

            // 2. Connect to ElevenLabs WebSocket
            let languageCode = currentSession?.language ?? settings.language
            try await sttService.connect(token: token, languageCode: languageCode)

            // 3. Start listening for STT events
            liveTranscript = ""
            isStreamingSTT = true
            startSTTEventListener(sttService: sttService)

            // 4. Start PCM recording and stream chunks to WebSocket
            await audioService.prepareForRecording()
            let sttRef = sttService
            try audioService.startStreamingRecording { pcmData in
                Task {
                    try? await sttRef.sendAudioChunk(pcmData)
                }
            }

            // 5. Start hard safety limit timer
            startAutoStopRecordingTimer()

            Logger.stt.info("🎙️ Streaming STT recording started")

        } catch {
            // Fallback to batch recording on any setup failure
            isStreamingSTT = false
            liveTranscript = ""
            await sttService.disconnect()

            Logger.stt.warning("⚠️ Streaming STT setup failed, falling back to batch: \(error, privacy: .public)")

            // Sentry: fallback metadata only — error type name, not the full description (may contain URLs/tokens).
            SentryLog.warn("STT fallback", category: .stt, attributes: [
                "reason": "streaming_setup_failed",
                "error_type": String(describing: type(of: error))
            ])

            await startBatchRecording()
        }
    }

    // MARK: - Streaming STT Events

    /// Listen for STT events and update live transcript / handle committed text
    private func startSTTEventListener(sttService: ElevenLabsSTTServiceProtocol) {
        sttEventTask?.cancel()
        sttEventTask = Task { [weak self] in
            for await event in sttService.events {
                guard let self, !Task.isCancelled else { break }

                switch event {
                case .partialTranscript(let text):
                    self.liveTranscript = text

                case .committedTranscript(let text):
                    self.liveTranscript = text
                    // Auto-stop recording and submit the committed text
                    await self.handleCommittedTranscript(text)
                    return

                case .connected:
                    break // Already handled in startStreamingRecording

                case .disconnected(let error):
                    if self.isStreamingSTT {
                        Logger.stt.warning("⚠️ STT disconnected unexpectedly: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                        // If we were mid-recording, fall back gracefully
                        self.isStreamingSTT = false
                        self.liveTranscript = ""
                    }
                    return
                }
            }
        }
    }

    /// Handle committed transcript from ElevenLabs VAD
    private func handleCommittedTranscript(_ text: String) async {
        guard quizState == .recording else { return }

        // Stop streaming recording
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        voiceCommandService?.setRecordingActive(false)
        audioService.stopStreamingRecording()
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false

        // Disconnect STT WebSocket
        sttEventTask?.cancel()
        sttEventTask = nil
        await sttService?.disconnect()
        isStreamingSTT = false

        Logger.stt.info("🎙️ Committed transcript: \(text, privacy: .public)")

        // Show confirmation modal with the transcribed text
        transcribedAnswer = text
        showAnswerConfirmation = true
        startAutoConfirmIfEnabled()
        // Stay in .recording → switch to a neutral state for the modal
        transition(to: .processing)
    }

    // MARK: - Silence Detection

    /// Subscribe to silence events and auto-stop recording when silence threshold reached
    private func startSilenceDetection(service: VoiceCommandServiceProtocol) {
        cancelSilenceDetection()

        silenceDetectionTask = Task { [weak self] in
            for await event in service.silenceEvents {
                guard let self, !Task.isCancelled else { break }
                guard self.quizState == .recording else { continue }

                switch event {
                case .speechStarted:
                    self.speechDetectedDuringAutoRecord = true
                case .silenceAfterSpeech(let duration):
                    Logger.audio.debug("🔇 Auto-record: silence threshold reached (\(String(format: "%.1f", duration), privacy: .public)s), auto-stopping")
                    await self.stopRecordingAndSubmit()
                    return
                }
            }
        }
    }

    /// Cancel silence detection subscription
    func cancelSilenceDetection() {
        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil
    }

    // MARK: - Stop & Submit

    /// Stop recording and submit the audio for evaluation
    func stopRecordingAndSubmit() async {
        // Guard against concurrent calls (silence detection + user tap can both trigger this)
        guard !isStoppingRecording else { return }
        isStoppingRecording = true
        defer { isStoppingRecording = false }

        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        voiceCommandService?.setRecordingActive(false)
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false

        if isStreamingSTT {
            // Streaming path: commit and let the event listener handle the response
            do {
                try await sttService?.commitAndClose()
                // The STT event listener will call handleCommittedTranscript
            } catch {
                // Cleanup and fallback
                isStreamingSTT = false
                audioService.stopStreamingRecording()
                await sttService?.disconnect()
                errorMessage = "Transcription failed: \(error.localizedDescription)"
                transition(to: .askingQuestion)
            }
        } else {
            // Batch path: stop M4A recording and upload
            do {
                let data = try await audioService.stopRecording()
                await submitVoiceAnswer(audioData: data)
            } catch {
                errorMessage = "Recording failed: \(error.localizedDescription)"
                transition(to: .askingQuestion)

                Logger.audio.error("❌ Recording stop failed: \(error, privacy: .public)")
            }
        }
    }

    /// Submit a voice answer with timeout and cancellation support
    func submitVoiceAnswer(audioData: Data) async {
        guard let sessionId = currentSession?.id else {
            setError(message: "No active session", context: .general)
            return
        }

        transition(to: .processing)
        errorMessage = nil

        // Create a task that can be cancelled via cancelProcessing()
        voiceSubmissionTask = Task { [weak self] in
            guard let self else { return }

            do {
                Logger.network.info("🎤 Submitting voice answer: \(audioData.count, privacy: .public) bytes")

                // Race the network call against a 30-second timeout
                let response = try await withUserFacingTimeout(seconds: 30) {
                    try await self.networkService.submitVoiceAnswer(
                        sessionId: sessionId,
                        audioData: audioData,
                        fileName: "answer.m4a"
                    )
                }

                // Check for cancellation before updating UI
                try Task.checkCancellation()

                // Check if response has a valid evaluation before showing confirmation
                guard let evaluation = response.evaluation else {
                    Logger.network.warning("⚠️ No evaluation in response - speech may not have been recognized")
                    await MainActor.run {
                        self.handleTranscriptionFailure()
                    }
                    return
                }

                // Reset failure counter on success
                await MainActor.run {
                    self.consecutiveTranscriptionFailures = 0
                }

                // Store response and show confirmation modal
                await MainActor.run {
                    self.pendingResponse = response
                    self.transcribedAnswer = evaluation.userAnswer
                    self.showAnswerConfirmation = true
                    self.startAutoConfirmIfEnabled()
                }

                // Don't call handleQuizResponse yet - wait for user confirmation

            } catch is CancellationError {
                // User cancelled - state already cleaned up by cancelProcessing()
                Logger.network.debug("🚫 Voice submission task was cancelled")
            } catch is TimeoutError {
                await MainActor.run {
                    self.setError(
                        message: "Request timed out. Please try again.",
                        context: .submission
                    )
                }

                Logger.network.error("⏱️ Voice submission timed out after 30 seconds")
            } catch let error as NetworkError {
                // Handle daily limit reached — show paywall
                if case .dailyLimitReached(let limitError) = error {
                    await MainActor.run {
                        self.dailyLimitError = limitError
                        self.showPaywall = true
                        self.transition(to: .idle)
                    }
                    return
                }

                // Handle "speech not understood" errors gracefully - let user re-record
                if case .serverError(let statusCode, _) = error, statusCode == 400 {
                    await MainActor.run {
                        self.handleTranscriptionFailure()
                    }

                    Logger.network.warning("⚠️ Speech not understood, tier \(self.consecutiveTranscriptionFailures, privacy: .public) escalation")
                    return
                }

                // Other network errors go to error screen
                await MainActor.run {
                    self.setError(
                        message: "Failed to submit answer: \(error.localizedDescription)",
                        context: .submission
                    )
                }

                Logger.network.error("❌ Error submitting answer: \(error, privacy: .public)")
            } catch {
                await MainActor.run {
                    self.setError(
                        message: "Failed to submit answer: \(error.localizedDescription)",
                        context: .submission
                    )
                }

                Logger.network.error("❌ Error submitting answer: \(error, privacy: .public)")
            }
        }

        // Wait for the task to complete
        await voiceSubmissionTask?.value
    }

    /// User-facing timeout error
    private struct TimeoutError: Error {}

    /// Runs an async operation with a timeout, throwing TimeoutError if exceeded
    private func withUserFacingTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                throw TimeoutError()
            }

            // Return first result, cancel the other
            guard let result = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Answer Confirmation

    /// Confirm the transcribed answer and proceed to show result
    func confirmAnswer() async {
        cancelAutoConfirm()
        showAnswerConfirmation = false

        // If we have a pending Whisper response, use it directly
        if let response = pendingResponse {
            pendingResponse = nil
            await handleQuizResponse(response)
            return
        }

        // Streaming STT path: submit the transcribed text via /sessions/{id}/input
        guard !transcribedAnswer.isEmpty else { return }
        await resubmitAnswer(transcribedAnswer)
    }

    /// Defense-in-depth cleanup if the answer confirmation sheet is dismissed
    /// without Confirm or Re-record (e.g., programmatic dismiss, future changes).
    /// No-op when pendingResponse was already consumed by confirmAnswer/rerecordAnswer.
    func handleAnswerConfirmationDismissed() {
        guard pendingResponse != nil else { return }
        pendingResponse = nil
        transition(to: .askingQuestion)
        errorMessage = nil
    }

    /// Reject the transcribed answer and return to ready-to-record state
    func rerecordAnswer() {
        cancelAutoConfirm()
        showAnswerConfirmation = false
        pendingResponse = nil
        isRerecording = true
        transition(to: .askingQuestion)  // Return to ready state, not recording
        errorMessage = nil
    }

    /// Cancel the processing operation and return to question state
    func cancelProcessing() {
        cancelAutoConfirm()
        voiceSubmissionTask?.cancel()
        voiceSubmissionTask = nil
        cancelAnswerTimer()
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        cleanupStreamingSTT()
        isAutoRecording = false
        speechDetectedDuringAutoRecord = false
        showAnswerConfirmation = false
        pendingResponse = nil
        transcribedAnswer = ""
        liveTranscript = ""
        transition(to: .askingQuestion)
        errorMessage = nil

        Logger.quiz.info("🚫 Voice submission cancelled by user")
    }

    /// Clean up streaming STT resources
    func cleanupStreamingSTT() {
        sttEventTask?.cancel()
        sttEventTask = nil
        sttChunkTask?.cancel()
        sttChunkTask = nil
        if isStreamingSTT {
            audioService.stopStreamingRecording()
            Task { await sttService?.disconnect() }
            isStreamingSTT = false
            liveTranscript = ""
        }
    }

    // MARK: - Transcription Failure Escalation

    /// 3-tier error escalation for transcription failures.
    /// Tier 1: Gentle re-record prompt
    /// Tier 2: Hint to speak closer
    /// Tier 3: Auto-skip after 2+ failures
    private func handleTranscriptionFailure() {
        consecutiveTranscriptionFailures += 1

        switch consecutiveTranscriptionFailures {
        case 1:
            // Tier 1: gentle retry
            errorMessage = "Sorry, I didn't catch that. Please try again."
            transition(to: .askingQuestion)
            announceError("Sorry, I didn't catch that. Please try again.")

        case 2:
            // Tier 2: hint + retry
            errorMessage = "Having trouble hearing you. Try speaking closer to the mic."
            transition(to: .askingQuestion)
            announceError("Having trouble hearing you. Try speaking closer to the mic.")

        default:
            // Tier 3: auto-skip
            consecutiveTranscriptionFailures = 0
            announceError("Skipping this one.")
            Task { await skipQuestion() }
        }
    }
}
