//
//  RecordingCoordinator+Streaming.swift
//  Hangs
//
//  Streaming-STT event handling (#113 T5): the ElevenLabs event listener and
//  the committed-transcript hand-off (MCQ voice fast-path + confirmation modal).
//

import Foundation
import os

// MARK: - Streaming STT Events

extension RecordingCoordinator {
    /// Listen for STT events and update live transcript / handle committed text
    /// (Internal, not private — started from +Capture's `startStreamingRecording`.)
    func startSTTEventListener(sttService: ElevenLabsSTTServiceProtocol) {
        // Fresh stream per recording session (StreamChannel): this listener is
        // cancelled on every teardown (commit watchdog, audio interruption, a
        // superseding typed answer) and so is the feedback sheet's dictation
        // listener on the SAME app-lifetime service. Cancelling a `for await`
        // finishes that stream's storage, so a shared stream left every later
        // voice answer with a dead event pipe — no transcript, watchdog timeout,
        // auto-skip. Acquired SYNCHRONOUSLY before the task so an event yielded
        // right after this call buffers instead of racing the task's startup.
        let stream = sttService.makeEventStream()
        let task = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }

                switch event {
                case let .partialTranscript(text):
                    self.liveTranscript = text
                    // Streaming has no local VAD, so a content-bearing partial
                    // is the speech signal: it keeps a spoken-but-lost answer
                    // on the tier-1 retry path instead of the unattended skip.
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.speechDetectedDuringAutoRecord = true
                    }

                case let .committedTranscript(text):
                    self.liveTranscript = text
                    // Auto-stop recording and submit the committed text
                    await self.handleCommittedTranscript(text)
                    return

                case .connected:
                    break // Already handled in startStreamingRecording

                case let .disconnected(error):
                    if self.isStreamingSTT {
                        Logger.stt.warning("⚠️ STT disconnected unexpectedly: \(error?.localizedDescription ?? "unknown", privacy: .public)")
                        // If we were mid-recording, fall back gracefully
                        self.isStreamingSTT = false
                        self.liveTranscript = ""
                        // A drop mid-recording must not strand the UI in
                        // .recording — stop the engine and return to
                        // ready-to-record (#54 task 54.4 stuck-state class).
                        if self.quizState() == .recording {
                            self.cancelAutoStopRecordingTimer()
                            self.audioService.stopStreamingRecording()
                            self.setIsAutoRecording(false)
                            self.speechDetectedDuringAutoRecord = false
                            self.setErrorMessage(String(localized: "Connection lost. Tap Record to try again.", comment: "Inline error when the streaming connection drops mid-recording"))
                            self.transition(to: .askingQuestion)
                        }
                    }
                    return
                }
            }
        }
        taskBag.add(task, key: .sttEvent)
    }

    /// Handle committed transcript from ElevenLabs VAD
    /// (internal so the MCQ-voice routing can be unit-tested directly — 45.3).
    func handleCommittedTranscript(_ text: String) async {
        guard quizState() == .recording else { return }

        // #79: snapshot the submission epoch. If a typed answer (or a skip / MCQ
        // tap) supersedes this transcript while we are suspended below, the epoch
        // moves and we must abort silently rather than fire a second submission or
        // resurrect the confirmation sheet with stale voice text.
        let epoch = submissionEpoch()

        // Dead air on an auto-started recording is "time's up", not a
        // transcription failure to retry (TF build 53). Two arrival paths:
        // ElevenLabs can commit spontaneously (its own VAD cap — the flags are
        // still live here), or the commit was forced by stopRecordingAndSubmit(),
        // whose prefix already cleared the flags and left us its snapshot.
        let wasUnattended = wasUnattendedRecording
            || (isAutoRecording() && !speechDetectedDuringAutoRecord)

        // Stop streaming recording
        cancelAutoStopRecordingTimer()
        taskBag.cancel(.sttCommitWatchdog)
        cancelSilenceDetection()
        audioService.stopStreamingRecording()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false

        // Disconnect STT WebSocket
        taskBag.cancel(.sttEvent)
        await sttService?.disconnect()
        isStreamingSTT = false

        // #79: the only suspension point before we branch is disconnect() above —
        // re-check the epoch now. A typed submission that raced in during that
        // await already tore down and submitted; both the MCQ branch and the
        // free-text confirmation tail below must be unreachable.
        guard submissionEpoch() == epoch else {
            Logger.stt.debug("🎙️ Committed transcript superseded (epoch moved) — ignoring")
            return
        }

        Logger.stt.info("🎙️ Committed transcript: \(text, privacy: .public)")

        // Dead air: a forced commit (15 s cap) returns an empty transcript.
        // Escalate as a transcription failure (retry prompt → auto-skip), never
        // an empty confirmation sheet (#54 task 54.4, founder #5).
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            handleTranscriptionFailure(unattendedSilence: wasUnattended)
            return
        }

        // MCQ voice path (45.3): resolve a spoken letter / ordinal / answer text
        // to an option and submit its value directly, skipping the confirmation
        // modal. An ambiguous / unrecognized transcript falls through to the
        // normal modal so the driver can re-record rather than submit a guess.
        if let question = currentQuestion(), question.isMultipleChoice,
           let key = MCQTranscriptMatcher.match(text, options: question.sortedAnswerOptions),
           let value = question.possibleAnswers?[key]
        {
            setMcqVoiceMatchedKey(key)
            // This code runs inside the .sttEvent listener task cancelled above,
            // and the submit's network call is cancellation-aware — awaiting it
            // directly throws URLError(.cancelled) mid-submit and surfaces the
            // OOPS screen (same self-cancellation class as 54.5). Hop to an
            // unstructured task, which does not inherit cancellation, and await
            // its value so direct callers keep synchronous semantics.
            await Task { await self.submitMCQAnswer(key, value) }.value
            return
        }

        // Show confirmation modal with the transcribed text
        transcribedAnswer = text
        showAnswerConfirmation = true
        startAutoConfirmIfEnabled()
        // Stay in .recording → switch to a neutral state for the modal
        transition(to: .processing)
        // #77 (77.5): confirmation window — re-arm the command listener for
        // "ok"/"again" (Session 4 routes them) on top of the 10 s auto-confirm.
        refreshCommandWindow()
    }
}
