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

        // #133 1a: bind the recording to the question that was on screen when the
        // user stopped talking — read here, synchronously, before the state moves or
        // any response can advance it. A retry of this upload is then replayed
        // against THAT question instead of grading the next, unseen one.
        let answeredQuestionId = currentQuestion()?.id

        transition(to: .processing)
        setErrorMessage(nil)

        // Create a task that can be cancelled via cancelProcessing()
        let task = Task { [weak self] in
            guard let self else { return }

            do {
                Logger.network.info("🎤 Submitting voice answer: \(audioData.count, privacy: .public) bytes")

                // Race the network call against a 30-second timeout. #131 Track A:
                // the bounded cold-wake retry sits INSIDE the timeout, so all three
                // attempts plus their 1s/2s backoff still land within the one
                // user-facing 30s budget — a staging machine waking up costs a
                // pause, never an OOPS screen.
                let backoff = self.transientBackoffOverride
                let response = try await withUserFacingTimeout(seconds: 30) {
                    try await TransientRetry.run(
                        label: "voice answer submit",
                        backoff: backoff
                    ) {
                        try await self.networkService.submitVoiceAnswer(
                            sessionId: sessionId,
                            audioData: audioData,
                            fileName: "answer.m4a",
                            questionId: answeredQuestionId
                        )
                    }
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

                // Store response and show confirmation modal — but only if this
                // coordinator still owns the submission. The submit path transitions to
                // `.processing` before its first await, so anything that has since left
                // `.processing` (a Re-record tap or a spoken "again", a Cancel, a skip)
                // has REJECTED this recording. Applying the result anyway put the stale
                // transcript back on screen and armed auto-confirm over the live
                // re-record; when that fired the rejected answer got graded and the
                // re-recorded one was dropped. Mirrors `handleQuizResponse`'s
                // "only the state that submitted may commit" guard (#133 V14).
                await MainActor.run {
                    guard self.quizState() == .processing else {
                        let state = self.quizState().label
                        Logger.network.info("🚫 Dropping voice submit result — state \(state, privacy: .public) no longer owns this submission")
                        return
                    }
                    self.pendingResponse = response
                    self.transcribedAnswer = evaluation.userAnswer
                    self.noAnswerCaptured = false
                    self.showAnswerConfirmation = true
                    self.startAutoConfirmIfEnabled()
                }

                // Don't call handleQuizResponse yet - wait for user confirmation

            } catch is CancellationError {
                // User cancelled - state already cleaned up by cancelProcessing()
                Logger.network.debug("🚫 Voice submission task was cancelled")
            } catch let error as URLError where error.code == .cancelled {
                // The same cancellation arriving from URLSession rather than from
                // `Task.checkCancellation()`. Re-record / Cancel abort this task
                // mid-request, and the rejected submission must vanish silently —
                // routing it to `setError` would raise an "Action cancelled" screen
                // over the recording the driver just started (#133 V14).
                Logger.network.debug("🚫 Voice submission cancelled mid-request")
            } catch let error as URLError where error.code == .timedOut {
                // #131 Track A: pass the error through. Without it `setError` fell
                // back to the context-only model and every failure — timeout,
                // cold wake, 5xx — rendered the same generic "Couldn't submit your
                // answer" OOPS. With it the user reads what actually happened.
                await MainActor.run {
                    self.setError(
                        message: String(localized: "Request timed out. Please try again.", comment: "Inline error when a voice answer submission times out"),
                        context: .submission,
                        error: error
                    )
                }

                Logger.network.error("⏱️ Voice submission timed out after 30 seconds")
            } catch let error as NetworkError {
                // Handle daily limit reached — show paywall
                if case .quotaLimitReached = error {
                    await self.handleError(error, context: .submission, fallbackMessage: String(localized: "Failed to submit answer", comment: "Error prefix when submitting a voice answer fails; error detail is appended"))
                    return
                }

                // "Speech not understood" (#171 Track B): no banner, no retry
                // loop — the empty confirmation sheet, where the driver can type
                // or re-record before it counts as no answer.
                if case let .serverError(statusCode, _) = error, statusCode == 400 {
                    await MainActor.run {
                        self.handleTranscriptionFailure()
                    }

                    Logger.network.warning("⚠️ Speech not understood — no-answer confirmation sheet")
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

    /// Runs an async operation with a timeout, throwing `URLError(.timedOut)` if
    /// exceeded. #131 Track A: a real `URLError` (not a private marker type) so
    /// `AppErrorModel.from` can map it to the accurate "Request timed out" copy
    /// instead of the generic submission fallback.
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
                throw URLError(.timedOut)
            }

            // Return first result, cancel the other
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }
    }
}
