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
        let heardSpeech = speechDetectedDuringAutoRecord
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
        } else if usesLegacyRecorder {
            // The no-engine fallback (see startLegacyRecorderFallback): M4A upload.
            usesLegacyRecorder = false
            do {
                let data = try await audioService.stopRecording()
                await submitVoiceAnswer(audioData: data)
            } catch {
                setErrorMessage(String(localized: "Recording failed: \(error.localizedDescription)", comment: "Inline error when audio recording fails; placeholder is the underlying error"))
                transition(to: .askingQuestion)

                Logger.audio.error("❌ Recording stop failed: \(error, privacy: .public)")
            }
        } else {
            // Batch path (#184 track B): stop the tee, wrap the PCM as WAV, upload.
            silenceDetectionService.setAnswerAudioSink(nil)
            let capture = answerCapture.finish()
            releaseAnswerEngineIfOwned()

            SentryLog.info("answer recording stopped", category: .audio, attributes: [
                "path": "batch",
                "durationMs": capture.durationMs,
                "bytes": capture.bytes,
                "droppedBytes": capture.droppedBytes,
                "heardSpeech": heardSpeech,
            ])

            // Under a fifth of a second of audio is dead air or an engine that
            // never delivered — not a transcription job. #171 Track B funnel.
            guard capture.bytes >= Self.minimumAnswerBytes(sampleRate: capture.sampleRate) else {
                Logger.audio.info("🎙️ Batch capture too short (\(capture.bytes, privacy: .public) bytes) — no-answer sheet")
                handleTranscriptionFailure()
                return
            }

            savedRecordingStamp = AnswerRecordingStore.save(
                wav: capture.wav,
                sidecar: AnswerRecordingStore.Sidecar(
                    recordedAt: Date(),
                    language: currentSession()?.language ?? settings().language,
                    inputPort: VoiceProcessingPolicy.currentInputPort(),
                    voiceProcessing: VoicePipelineFlags.voiceProcessingEnabled,
                    sampleRate: capture.sampleRate,
                    durationMs: capture.durationMs,
                    questionId: currentQuestion()?.id
                )
            )
            await submitVoiceAnswer(audioData: capture.wav, fileName: "answer.wav")
        }
    }

    /// 0.2 s of 16-bit mono at `sampleRate` — the floor under which a capture is
    /// treated as "nothing captured" instead of being uploaded.
    static func minimumAnswerBytes(sampleRate: Int) -> Int {
        sampleRate * 2 / 5
    }

    /// Submit a voice answer with timeout and cancellation support.
    /// `fileName` tells the backend the container: `answer.wav` from the #184
    /// batch capture, `answer.m4a` for any legacy caller.
    func submitVoiceAnswer(audioData: Data, fileName: String = "answer.m4a") async {
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
                let clock = self.clock
                let response = try await withUserFacingTimeout(seconds: 30, clock: clock) {
                    try await TransientRetry.run(
                        label: "voice answer submit",
                        clock: clock
                    ) {
                        try await self.networkService.submitVoiceAnswer(
                            sessionId: sessionId,
                            audioData: audioData,
                            fileName: fileName,
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
                    if let stamp = self.savedRecordingStamp {
                        AnswerRecordingStore.attachTranscript(evaluation.userAnswer, provider: nil, to: stamp)
                        self.savedRecordingStamp = nil
                    }
                    // #184 track D: the sheet opens AND the recognised answer is
                    // read back; auto-confirm + the "ok"/"again" window arm after.
                    self.presentVoiceTranscript(evaluation.userAnswer)
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
}
