//
//  RecordingCoordinator+Submission.swift
//  Hangs
//
//  The stop → transcribe → submit path (#113 T5): stopRecordingAndSubmit,
//  the batch voice-answer upload, and the user-facing submission timeout.
//

import Foundation
import os

// MARK: - Stop & Submit

extension RecordingCoordinator {
    /// Stop recording and submit the audio for evaluation
    func stopRecordingAndSubmit() async {
        // Guard against concurrent calls (silence detection + user tap can both trigger this)
        guard !isStoppingRecording else { return }
        isStoppingRecording = true
        defer { isStoppingRecording = false }

        emitEarcon(.gotIt) // 77.10 got-it tone — recording stopped / auto-submitted
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false

        if isStreamingSTT {
            // Streaming path: commit and let the event listener handle the response
            do {
                try await sttService?.commitAndClose()
                // The STT event listener will call handleCommittedTranscript.
                // If ElevenLabs never answers the forced commit (dead air, dropped
                // socket), only this watchdog stops the UI from showing RECORDING
                // forever (#54 task 54.4, founder #5).
                startCommitWatchdog()
            } catch {
                // Cleanup and fallback
                isStreamingSTT = false
                audioService.stopStreamingRecording()
                await sttService?.disconnect()
                setErrorMessage(String(localized: "Transcription failed: \(error.localizedDescription)", comment: "Inline error when streaming speech-to-text fails; placeholder is the underlying error"))
                transition(to: .askingQuestion)
            }
        } else {
            // Batch path: stop M4A recording and upload
            do {
                let data = try await audioService.stopRecording()
                await submitVoiceAnswer(audioData: data)
            } catch {
                setErrorMessage(String(localized: "Recording failed: \(error.localizedDescription)", comment: "Inline error when audio recording fails; placeholder is the underlying error"))
                transition(to: .askingQuestion)

                Logger.audio.error("❌ Recording stop failed: \(error, privacy: .public)")
            }
        }
    }

    /// Submit a voice answer with timeout and cancellation support
    func submitVoiceAnswer(audioData: Data) async {
        guard let sessionId = currentSession()?.id else {
            setError(message: String(localized: "No active session", comment: "Inline error: no quiz session is currently active"), context: .general)
            return
        }

        transition(to: .processing)
        setErrorMessage(nil)

        // Create a task that can be cancelled via cancelProcessing()
        let task = Task { [weak self] in
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
                        message: String(localized: "Request timed out. Please try again.", comment: "Inline error when a voice answer submission times out"),
                        context: .submission
                    )
                }

                Logger.network.error("⏱️ Voice submission timed out after 30 seconds")
            } catch let error as NetworkError {
                // Handle daily limit reached — show paywall
                if case .quotaLimitReached = error {
                    await self.handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to submit answer", comment: "Error prefix when submitting a voice answer fails; error detail is appended"))
                    return
                }

                // Handle "speech not understood" errors gracefully - let user re-record
                if case let .serverError(statusCode, _) = error, statusCode == 400 {
                    await MainActor.run {
                        self.handleTranscriptionFailure()
                    }

                    Logger.network.warning("⚠️ Speech not understood, tier \(self.consecutiveTranscriptionFailures, privacy: .public) escalation")
                    return
                }

                // Other network errors go to error screen
                await MainActor.run {
                    self.setError(
                        message: String(localized: "Failed to submit answer: \(error.localizedDescription)", comment: "Inline error when submitting a voice answer fails; placeholder is the underlying error"),
                        context: .submission,
                        error: error
                    )
                }

                Logger.network.error("❌ Error submitting answer: \(error, privacy: .public)")
            } catch {
                await MainActor.run {
                    self.setError(
                        message: String(localized: "Failed to submit answer: \(error.localizedDescription)", comment: "Inline error when submitting a voice answer fails; placeholder is the underlying error"),
                        context: .submission,
                        error: error
                    )
                }

                Logger.network.error("❌ Error submitting answer: \(error, privacy: .public)")
            }
        }
        taskBag.add(task, key: .voiceSubmission)

        // Wait for the task to complete
        await task.value
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
}
