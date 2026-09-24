//
//  RecordingCoordinator+Capture.swift
//  Hangs
//
//  Capture lifecycle (#113 T5): toggle/start recording (batch + streaming),
//  silence detection, the STT commit watchdog, transcription-failure
//  escalation, and audio-interruption recovery.
//

import Clocks
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
            // #171 Track H: remember WHEN the window was due to open. The
            // countdowns keep running in the background (founder decision), so
            // foregrounding must either open the mic (window still has time) or
            // close the question out on the no-answer sheet — never leave the
            // driver parked on a question whose countdown ran out unseen.
            if backgroundSuppressedRecordingAt == nil {
                backgroundSuppressedRecordingAt = clock.now
            }
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
        backgroundSuppressedRecordingAt = nil
        setErrorMessage(nil)
        transition(to: .recording)
        // Nothing has been heard in THIS recording yet — the flag is what
        // `armRecordingWindow` reads to catch a speech signal that arrived while
        // the engine was still coming up, so it must not carry over from the
        // previous one.
        speechDetectedDuringAutoRecord = false
        emitEarcon(.micLive) // 77.10 mic-live tone — the mic just opened

        // #131 Track B armed the recording window HERE, before the engine was up,
        // so the button never showed a blank countdown during the handshake.
        // #173 moves it to each path's "the mic is now actually open" line
        // (`armRecordingWindow`): the window it arms is 5 s of "time to start
        // speaking", and starting that clock while the WebSocket is still
        // connecting spends the driver's time on our setup — on a slow start it
        // ran out before the mic ever opened and submitted an empty answer. The
        // button is numberless for the setup gap, which is honest: there is
        // nothing to count down yet.
        //
        // The HIDDEN cap is armed here all the same. It is not a countdown, it
        // is the promise that this recording ends: a handshake that never
        // returns (dead socket, an engine that refuses to start) would
        // otherwise leave the mic open in `.recording` with no deadline at all,
        // which is the guarantee #131 Track B's arming used to carry.
        armRecordingDeadAirCap(deadAirCap)

        // #184: realtime is a runtime A/B choice now (VoicePipelineFlags); the
        // default answer path is local VAD → WAV → backend batch transcription.
        if Config.useElevenLabsSTT, sttService != nil, realtimeSTTEnabled() {
            await startStreamingRecording()
        } else {
            await startBatchRecording()
        }
    }

    /// Arm the recording window at the one moment it is honest: the mic is open.
    ///
    /// `hasSpeechSignal` is what decides its length (#173). The short "time to
    /// start speaking" can only be retired by a streaming partial transcript or
    /// auto-record's VAD; a path with neither keeps the dead-air cap as its
    /// visible window, or the mic would close mid-sentence with nothing able to
    /// say the driver was speaking.
    private func armRecordingWindow(hasSpeechSignal: Bool) {
        startAutoStopRecordingTimer(hasSpeechSignal ? speechStartWindow : deadAirCap, deadAirCap)

        // The driver may already have been heard while the engine was coming up
        // (auto-record's VAD fires `.speechStarted` exactly ONCE per recording).
        // Retiring the countdown is guarded on there being one, so a signal that
        // landed in the setup gap would be swallowed and the 5 s would then run
        // out under an answer already in progress.
        if speechDetectedDuringAutoRecord { onSpeechStarted() }
    }

    /// Start the batch answer recording (#184 track B).
    ///
    /// The shared mic engine (SilenceDetectionService) is the recorder: its tap
    /// tees the post-voice-processing PCM the on-device VAD already sees into
    /// `answerCapture`, the VAD's silence-after-speech ends the recording for
    /// EVERY batch recording (auto and manual — parity with the realtime path's
    /// server VAD), and the WAV goes to the backend for Scribe v2 batch
    /// transcription. No `AVAudioRecorder` next to the engine any more: that was
    /// a second mic client that never saw the voice processing (#64/#77 class).
    private func startBatchRecording() async {
        await audioService.prepareForRecording()

        // The engine is normally already up — the command window armed it after
        // the question TTS. Voice commands OFF (or a window that never armed)
        // means nobody did, so this recording starts it and later stops it.
        if !silenceDetectionService.isListening, !silenceDetectionService.isStartingListening {
            startedListenerForAnswer = true
            await silenceDetectionService.startListening()
        }

        // #174: the dead-air cap armed in `startRecording` (or a teardown) may
        // have ended this recording while the engine was still coming up — the
        // state is no longer `.recording`. Arm nothing; release what we own.
        guard quizState() == .recording else {
            releaseAnswerEngineIfOwned()
            Logger.audio.info("🎙️ Recording ended during engine start — no capture armed")
            return
        }

        // No engine and none coming up (the recognizer setup failed — the
        // #77 degrade-to-buttons case): the mic button must still work, so fall
        // back to the plain recorder rather than refusing to record.
        guard silenceDetectionService.isListening || silenceDetectionService.isStartingListening else {
            startedListenerForAnswer = false
            await startLegacyRecorderFallback()
            return
        }

        let sampleRate = Int(silenceDetectionService.answerAudioSampleRate)
        let capture = answerCapture
        capture.begin(sampleRate: sampleRate)
        silenceDetectionService.setAnswerAudioSink { capture.append($0) }

        speechDetectedDuringAutoRecord = false
        // #185 track A: a fresh detection session per recording — nothing the
        // command window's VAD saw may decide this answer (H3) — with the lower
        // blip bar when the whole answer can be one syllable ("c", "dva").
        noSpeechWindowDeferral = nil
        silenceDetectionService.beginAnswerDetection(
            minSpeechDuration: currentQuestion()?.isMultipleChoice == true
                ? VADTuning.mcqMinSpeechDurationSecs
                : VADTuning.minSpeechDurationSecs
        )
        startSilenceDetection(service: silenceDetectionService)

        // The capture is armed and the VAD's `.speechStarted` is the speech
        // signal, so this path gets the founder's 5 s "time to start speaking".
        armRecordingWindow(hasSpeechSignal: true)

        SentryLog.info("answer recording started", category: .audio, attributes: [
            "path": "batch",
            "inputPort": VoiceProcessingPolicy.currentInputPort(),
            "inputHz": sampleRate,
            "voiceProcessing": VoicePipelineFlags.voiceProcessingEnabled,
        ])
    }

    /// The pre-#184 recorder (`AVAudioRecorder`, M4A): no voice processing and
    /// no VAD, so the hidden dead-air cap is what ends it. Fail-loud in the
    /// telemetry — a device that lands here every time has a broken mic engine.
    private func startLegacyRecorderFallback() async {
        do {
            try audioService.startRecording()
            usesLegacyRecorder = true
            SentryLog.warn("answer recording on legacy recorder", category: .audio, attributes: [
                "reason": "mic_engine_unavailable",
                "inputPort": VoiceProcessingPolicy.currentInputPort(),
            ])
            // No speech signal on this path (no VAD, no partial transcripts):
            // the dead-air cap is the visible window, as before #173.
            armRecordingWindow(hasSpeechSignal: false)
        } catch {
            cancelAutoStopRecordingTimer() // mic never opened — drop the window
            setIsAutoRecording(false)
            speechDetectedDuringAutoRecord = false
            transition(to: .askingQuestion)
            setErrorMessage(String(localized: "Recording failed: \(error.localizedDescription)", comment: "Inline error when audio recording fails; placeholder is the underlying error"))

            Logger.audio.error("❌ Recording failed to start: \(error, privacy: .public)")
        }
    }

    /// Stop the shared mic engine again — only when THIS recording started it.
    func releaseAnswerEngineIfOwned() {
        guard startedListenerForAnswer else { return }
        startedListenerForAnswer = false
        stopSilenceDetectionListening()
    }

    /// Drop an in-progress batch capture without submitting — the teardown
    /// paths (interruption, background, a typed answer superseding the mic).
    func abandonAnswerCapture() {
        silenceDetectionService.setAnswerAudioSink(nil)
        _ = silenceDetectionService.endAnswerDetection()
        answerCapture.cancel()
        savedRecordingStamp = nil
        releaseAnswerEngineIfOwned()
        if usesLegacyRecorder {
            usesLegacyRecorder = false
            Task { [audioService] in _ = try? await audioService.stopRecording() }
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

            // #174: same race as the batch path — the cap fired (or a teardown
            // ran) during the token/WebSocket/engine handshake. Tear the stream
            // down rather than arm a window nothing can close.
            guard quizState() == .recording else {
                cleanupStreamingSTT()
                Logger.stt.info("🎙️ Streaming recording ended during handshake — stream closed, no window armed")
                return
            }

            // The mic is open and the event stream is live: partial transcripts
            // are the speech signal, so this path gets the founder's 5 s.
            armRecordingWindow(hasSpeechSignal: true)

            Logger.stt.info("🎙️ Streaming STT recording started")

        } catch is CancellationError {
            // A teardown (scene-phase background, stop command) raced the streaming
            // start's settle wait — recording must stay stopped, so no batch fallback.
            cancelAutoStopRecordingTimer()
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
                    self.noteSpeechStarted()
                case let .silenceAfterSpeech(duration):
                    Logger.audio.debug("🔇 Auto-record: silence threshold reached (\(String(format: "%.1f", duration), privacy: .public)s), auto-stopping")
                    await self.stopRecordingAndSubmit(reason: .vad)
                    return
                }
            }
        }
        taskBag.add(task, key: .silenceDetection)
    }

    /// The driver is audibly answering — recorded once per recording by BOTH
    /// speech paths (on-device VAD above, and a content-bearing ElevenLabs
    /// partial on the streaming path, which has no local VAD).
    ///
    /// #173: this is also what retires the visible "time to start speaking"
    /// countdown. The two signals are the same fact, so they share one funnel —
    /// a path that set the flag without hiding the countdown would leave the
    /// driver watching a 5 s clock run out under an answer already in progress.
    func noteSpeechStarted() {
        speechDetectedDuringAutoRecord = true
        onSpeechStarted()
    }

    /// #185 track A (founder 2026-09-24): the visible 5 s "time to start
    /// speaking" window may end a batch recording only when the on-device
    /// detector demonstrably works and heard nothing that could be speech. In
    /// the car the old detector heard nothing ever, so every answer was cut at
    /// 5 s. When the detector cannot vouch, the countdown just disappears and
    /// the hidden dead-air cap ends the recording instead — a late or quiet
    /// answer is never cut off by a deaf detector. The realtime stream (partial
    /// transcripts are its signal) and the legacy recorder (its window IS the
    /// cap) keep the plain expiry.
    func noSpeechWindowMayEndRecording() -> Bool {
        guard !isStreamingSTT, !usesLegacyRecorder else { return true }
        let verdict = silenceDetectionService.noSpeechWindowVerdict
        guard !verdict.mayEndRecording else { return true }
        noSpeechWindowDeferral = verdict
        onSpeechStarted() // hides the countdown; the dead-air cap keeps running
        Logger.audio.info("🎙️ No-speech window deferred to the cap (\(verdict.rawValue, privacy: .public))")
        return false
    }

    // MARK: - STT Commit Watchdog

    /// Rescue net for the streaming path's fire-and-forget commit: if no
    /// committed transcript resolves the state within `seconds`, clean up and
    /// hand over to `handleTranscriptionFailure()` instead of leaving the UI
    /// stuck on RECORDING. Cancelled by handleCommittedTranscript / cancelProcessing.
    /// `seconds` is injectable for tests; production callers use the default.
    func startCommitWatchdog(seconds: TimeInterval = Config.sttCommitWatchdogSecs) {
        let clock = clock
        let task = Task { [weak self] in
            try? await clock.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            guard self.quizState() == .recording else { return }

            Logger.stt.warning("⏱️ STT commit watchdog fired — no committed transcript within \(seconds, privacy: .public)s")

            self.cleanupStreamingSTT()
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
        abandonAnswerCapture()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        transition(to: .askingQuestion)
        setErrorMessage(String(localized: "Recording interrupted. Tap the mic to try again.", comment: "Shown when a phone call or other audio interruption stops recording"))
        Logger.audio.warning("⚠️ Recording interrupted by audio session — reset to ready state")
    }

    // MARK: - No Answer Captured

    /// The single funnel for "the recording produced nothing usable". Four paths
    /// reach it: an empty committed transcript, the STT commit watchdog, a
    /// Whisper response with no evaluation, and the backend's 400 "speech not
    /// understood". Track H adds a fifth — the answer window elapsed entirely
    /// while the app was backgrounded.
    ///
    /// #171 Track B (founder 2026-09-05): none of them may restart the answer
    /// window. The old 3-tier escalation showed "Sorry, I didn't catch that",
    /// re-armed a FULL think+answer countdown, did it a second time, and only
    /// then skipped — which reads as a broken timer from the driver's seat, and
    /// on the TF round it was the single most confusing behaviour. Every path
    /// now ends where every other answer ends: the confirmation sheet, with an
    /// EMPTY field. The driver can type the answer, say "again" to re-record,
    /// or let the 5 s auto-confirm expire — confirming an empty field submits
    /// "no answer" and moves on to the result (see `confirmAnswer()`).
    /// (Internal, not private — also called from +Streaming and +Submission.)
    func handleTranscriptionFailure() {
        // Kept for diagnostics only (it no longer changes the outcome): dead air
        // and a spoken-but-lost answer now end identically, and the TF loop's
        // first question about a "no answer" result is which of the two it was.
        let heardSpeech = speechDetectedDuringAutoRecord
        cancelAutoStopRecordingTimer()
        setIsAutoRecording(false)
        speechDetectedDuringAutoRecord = false
        // No banner: the empty sheet IS the message, and an error banner under
        // it would re-introduce the "something went wrong, try again" reading.
        setErrorMessage(nil)

        // The sheet is a `.processing` screen. The Whisper / 400 paths are
        // already there and `.processing → .processing` is not a legal edge, so
        // only move when we are arriving from somewhere else.
        if quizState() != .processing {
            guard transition(to: .processing) else { return }
        }

        pendingResponse = nil
        transcribedAnswer = ""
        noAnswerCaptured = true
        showAnswerConfirmation = true
        startAutoConfirmIfEnabled()
        // #77 (77.5): same command window as any other confirmation — "ok" /
        // "again" must work here too.
        refreshCommandWindow()

        Logger.stt.info("🎙️ Nothing captured (speech heard: \(heardSpeech, privacy: .public)) — confirmation sheet opened with an empty answer")
    }
}
