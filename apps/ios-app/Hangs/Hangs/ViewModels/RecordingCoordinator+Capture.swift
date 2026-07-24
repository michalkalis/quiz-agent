//
//  RecordingCoordinator+Capture.swift
//  Hangs
//
//  Capture lifecycle (#113 T5): toggle/start recording (batch + streaming),
//  silence detection, the STT commit watchdog, transcription-failure
//  escalation, and audio-interruption recovery.
//

import Foundation
import os
import Sentry

// MARK: - Recording Lifecycle

extension RecordingCoordinator {
    /// Toggle recording: start if asking a question, stop and submit if recording
    func toggleRecording() async {
        switch quizState() {
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
        // Backgrounded → never open the mic. Auto-record's thinking-time
        // countdown can fire after question TTS finishes in the background
        // (UIBackgroundModes audio keeps us running); stay on the question
        // instead — the user taps the mic or says "start" once foregrounded.
        guard isAppForeground() else {
            Logger.audio.info("🎙️ startRecording suppressed — app is backgrounded")
            return
        }

        // Mutual single-engine guard (#109): the feedback sheet can hold the shared
        // AVAudioEngine while dictating, and the auto-record / thinking-time timers
        // keep ticking under the modal sheet — so this is reachable. Never open a
        // second engine on top of it (the #64/#77 two-engine crash class); stay on
        // the question, the user records once the sheet closes.
        guard !audioService.isStreamingEngineActive else {
            Logger.audio.info("🎙️ startRecording suppressed — shared audio engine already active (feedback dictation)")
            return
        }

        // #110 Bug 2: starting an answer (voice or tap) supersedes any pending skip.
        abortSkipUndoWindow()

        cancelAnswerTimer()
        setErrorMessage(nil)
        transition(to: .recording)
        emitEarcon(.micLive) // 77.10 mic-live tone — the mic just opened

        // Choose streaming STT or batch M4A based on feature flag
        if Config.useElevenLabsSTT, sttService != nil {
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

            if isAutoRecording() {
                speechDetectedDuringAutoRecord = false
                startSilenceDetection(service: silenceDetectionService)
            }

            startAutoStopRecordingTimer()
        } catch {
            setIsAutoRecording(false)
            speechDetectedDuringAutoRecord = false
            transition(to: .askingQuestion)
            setErrorMessage(String(localized: "Recording failed: \(error.localizedDescription)", comment: "Inline error when audio recording fails; placeholder is the underlying error"))

            Logger.audio.error("❌ Recording failed to start: \(error, privacy: .public)")
        }
    }

    /// Start streaming recording with ElevenLabs Scribe v2 Realtime STT
    func startStreamingRecording() async {
        guard let sttService else {
            // Fallback to batch if STT service unavailable
            await startBatchRecording()
            return
        }

        // Flip UI flags up front so the LISTENING card appears the moment the
        // user taps the mic, not after the WebSocket handshake + first partial.
        // Catch block resets these on setup failure before falling back to batch.
        liveTranscript = ""
        isStreamingSTT = true

        // #77 (77.7 / E-topology): converge on ONE AVAudioEngine. The shared
        // VAD/command-listener engine (SilenceDetectionService) must be torn down
        // BEFORE the ElevenLabs streaming engine spins up — the two must never run
        // concurrently (the #64 two-engine crash config). Command listening and the
        // answer stream are time-disjoint; this is the enforcement point.
        stopSilenceDetectionListening()

        do {
            // 1. Get single-use token from backend
            let token = try await networkService.fetchElevenLabsToken()

            // 2. Connect to ElevenLabs WebSocket
            let languageCode = currentSession()?.language ?? settings().language
            try await sttService.connect(token: token, languageCode: languageCode)

            // 3. Start listening for STT events
            startSTTEventListener(sttService: sttService)

            // 4. Start PCM recording and stream chunks to WebSocket
            await audioService.prepareForRecording()
            let sttRef = sttService
            try await audioService.startStreamingRecording { pcmData in
                Task {
                    try? await sttRef.sendAudioChunk(pcmData)
                }
            }

            // 5. Start hard safety limit timer
            startAutoStopRecordingTimer()

            Logger.stt.info("🎙️ Streaming STT recording started")

        } catch is CancellationError {
            // A teardown (scene-phase background, stop command) raced the streaming
            // start's settle wait — recording must stay stopped, so no batch fallback.
            isStreamingSTT = false
            liveTranscript = ""
            await sttService.disconnect()
            Logger.stt.info("🎙️ Streaming STT start cancelled by teardown — no fallback")
        } catch {
            // Fallback to batch recording on any setup failure
            isStreamingSTT = false
            liveTranscript = ""
            await sttService.disconnect()

            Logger.stt.warning("⚠️ Streaming STT setup failed, falling back to batch: \(error, privacy: .public)")

            // Sentry: fallback metadata only — error type name, not the full description (may contain URLs/tokens).
            SentryLog.warn("STT fallback", category: .stt, attributes: [
                "reason": "streaming_setup_failed",
                "error_type": String(describing: type(of: error)),
            ])

            await startBatchRecording()
        }
    }

    // MARK: - Silence Detection

    /// Subscribe to silence events and auto-stop recording when silence threshold reached
    private func startSilenceDetection(service: SilenceDetectionServiceProtocol) {
        cancelSilenceDetection()

        // Acquired synchronously (see startCommandConsumer): an event fired right
        // after this call must buffer into the new stream, not race task startup.
        let silenceStream = service.makeSilenceEventStream()
        let task = Task { [weak self] in
            for await event in silenceStream {
                guard let self, !Task.isCancelled else { break }
                guard self.quizState() == .recording else { continue }

                switch event {
                case .speechStarted:
                    self.speechDetectedDuringAutoRecord = true
                case let .silenceAfterSpeech(duration):
                    Logger.audio.debug("🔇 Auto-record: silence threshold reached (\(String(format: "%.1f", duration), privacy: .public)s), auto-stopping")
                    await self.stopRecordingAndSubmit()
                    return
                }
            }
        }
        taskBag.add(task, key: .silenceDetection)
    }

    // MARK: - STT Commit Watchdog

    /// Rescue net for the streaming path's fire-and-forget commit: if no
    /// committed transcript resolves the state within `seconds`, clean up and
    /// escalate as a transcription failure instead of leaving the UI stuck on
    /// RECORDING. Cancelled by handleCommittedTranscript / cancelProcessing.
    /// `seconds` is injectable for tests; production callers use the default.
    func startCommitWatchdog(seconds: TimeInterval = Config.sttCommitWatchdogSecs) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.quizState() == .recording else { return }

            Logger.stt.warning("⏱️ STT commit watchdog fired — no committed transcript within \(seconds, privacy: .public)s")

            self.cleanupStreamingSTT()
            self.cancelAutoStopRecordingTimer()
            self.setIsAutoRecording(false)
            self.speechDetectedDuringAutoRecord = false
            self.handleTranscriptionFailure()
        }
        taskBag.add(task, key: .sttCommitWatchdog)
    }

    // MARK: - Audio Interruption

    /// Recover from an audio-session interruption (e.g. an incoming phone call)
    /// that tore down streaming recording. Leaves `.recording`, resets streaming
    /// STT, and clears the recording timers so no recording is stranded after the
    /// call (#67 Part A). No-op unless we were recording.
    func handleAudioInterruption() {
        guard quizState() == .recording else { return }
        cancelAutoStopRecordingTimer()
        cancelSilenceDetection()
        cleanupStreamingSTT()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        transition(to: .askingQuestion)
        setErrorMessage(String(localized: "Recording interrupted. Tap the mic to try again.", comment: "Shown when a phone call or other audio interruption stops recording"))
        Logger.audio.warning("⚠️ Recording interrupted by audio session — reset to ready state")
    }

    // MARK: - Transcription Failure Escalation

    /// 3-tier error escalation for transcription failures. Messages are shown
    /// visually via `errorMessage`; we intentionally don't announce them via TTS.
    /// Tier 1–2: Show retry prompt
    /// Tier 3: Auto-skip after 2+ failures
    /// (Internal, not private — also called from +Streaming and +Submission.)
    func handleTranscriptionFailure() {
        consecutiveTranscriptionFailures += 1

        switch consecutiveTranscriptionFailures {
        case 1:
            setErrorMessage(String(localized: "Sorry, I didn't catch that. Please try again.", comment: "Transcription failure tier 1: ask the user to retry"))
            transition(to: .askingQuestion)

        case 2:
            setErrorMessage(String(localized: "Having trouble hearing you. Try speaking closer to the mic.", comment: "Transcription failure tier 2: suggest speaking closer to the mic"))
            transition(to: .askingQuestion)

        default:
            consecutiveTranscriptionFailures = 0
            Task { await self.skipQuestion() }
        }
    }
}
