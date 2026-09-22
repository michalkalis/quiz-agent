//
//  AnswerPipelineTests.swift
//  HangsTests
//
//  #184 — the batch answer pipeline (tracks A–D): PCM → WAV, the capture
//  accumulator, the car-sample store, the record → VAD-stop → WAV upload flow on
//  the shared mic engine, the realtime A/B switch, and the confirmation-sheet
//  read-back of a voice answer. Every test says WHY the behaviour matters.
//

import Clocks
import Foundation
import Testing
@testable import Hangs

// MARK: - WAV / PCM (pure)

@Suite("#184 WAV encoder + answer capture")
struct WAVAndCaptureTests {
    /// WHY: the backend (and the offline comparison script) parse the WAV
    /// header — a wrong sample rate or size field makes Scribe misread the clip.
    @Test("WAV header carries RIFF/WAVE markers, the sample rate and the data size")
    func wavHeader() {
        let samples = Data(repeating: 0x7F, count: 3200) // 0.1 s at 16 kHz
        let wav = WAVEncoder.wav(pcm16: samples, sampleRate: 16000)

        #expect(wav.count == WAVEncoder.headerSize + samples.count)
        #expect(String(decoding: wav[0 ..< 4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8 ..< 12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wav[36 ..< 40], as: UTF8.self) == "data")
        #expect(readLE32(wav, at: 24) == 16000, "sample rate")
        #expect(readLE32(wav, at: 28) == 32000, "byte rate = rate × 2 bytes mono")
        #expect(readLE32(wav, at: 40) == UInt32(samples.count), "data chunk size")
        #expect(readLE32(wav, at: 4) == UInt32(36 + samples.count), "RIFF size")
    }

    /// WHY: `finish()` is what the submit path and the telemetry read — its
    /// duration must be derived from the bytes at the capture's own rate.
    @Test("capture accumulates only while active and reports the duration")
    func captureLifecycle() {
        let capture = AnswerCapture(maxSeconds: 10)
        capture.append(Data(count: 100)) // inactive — dropped
        capture.begin(sampleRate: 16000)
        #expect(capture.isActive)
        capture.append(Data(count: 16000)) // 0.5 s
        capture.append(Data(count: 16000)) // 0.5 s

        let result = capture.finish()
        #expect(!capture.isActive)
        #expect(result.bytes == 32000)
        #expect(result.durationMs == 1000)
        #expect(result.sampleRate == 16000)
        #expect(result.droppedBytes == 0)
        #expect(result.wav.count == WAVEncoder.headerSize + 32000)
    }

    /// WHY: a recording nothing ever closes must not grow unbounded — the cap
    /// mirrors the dead-air cap and the overflow is counted, not silently lost.
    @Test("capture drops past its byte cap and counts what it dropped")
    func captureCap() {
        let capture = AnswerCapture(maxSeconds: 1, sampleRate: 16000) // 32 000 bytes
        capture.begin(sampleRate: 16000)
        capture.append(Data(count: 30000))
        capture.append(Data(count: 4000)) // would exceed → dropped whole
        let result = capture.finish()
        #expect(result.bytes == 30000)
        #expect(result.droppedBytes == 4000)
    }

    /// WHY: teardown paths must discard without producing an upload.
    @Test("cancel discards the buffer")
    func captureCancel() {
        let capture = AnswerCapture()
        capture.begin(sampleRate: 16000)
        capture.append(Data(count: 3200))
        capture.cancel()
        #expect(!capture.isActive)
        #expect(capture.finish().bytes == 0)
    }

    private func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset ..< offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
}

// MARK: - Car-sample store (pure file I/O in a temp dir)

@Suite("#184 answer recording store")
struct AnswerRecordingStoreTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnswerRecordingStoreTests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    private func sidecar() -> AnswerRecordingStore.Sidecar {
        AnswerRecordingStore.Sidecar(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            language: "sk", inputPort: "MicrophoneBuiltIn", voiceProcessing: true,
            sampleRate: 16000, durationMs: 1200, questionId: "q_001"
        )
    }

    /// WHY: privacy — with the switch off, nothing is ever written.
    @Test("saving is a no-op when the switch is off")
    func disabledSavesNothing() {
        let dir = tempDir()
        let stamp = AnswerRecordingStore.save(wav: Data(count: 44), sidecar: sidecar(), enabled: false, directory: dir)
        #expect(stamp == nil)
        #expect(AnswerRecordingStore.recordingCount(directory: dir) == 0)
    }

    /// WHY: the offline comparison needs the WAV AND the metadata AND — once
    /// the backend answers — the transcript it produced, all under one stamp.
    @Test("save writes WAV + sidecar, the transcript is attached later, delete clears")
    func saveAttachDelete() throws {
        let dir = tempDir()
        defer { AnswerRecordingStore.deleteAll(directory: dir) }

        let stamp = AnswerRecordingStore.save(wav: Data(count: 44), sidecar: sidecar(), enabled: true, directory: dir)
        #expect(stamp == "20231114-221320-000")
        #expect(AnswerRecordingStore.recordingCount(directory: dir) == 1)
        #expect(AnswerRecordingStore.files(directory: dir).map(\.pathExtension) == ["json", "wav"])

        AnswerRecordingStore.attachTranscript("Bratislava", provider: "scribe", to: stamp!, directory: dir)
        let json = try Data(contentsOf: dir.appendingPathComponent("\(stamp!).json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnswerRecordingStore.Sidecar.self, from: json)
        #expect(decoded.transcript == "Bratislava")
        #expect(decoded.provider == "scribe")
        #expect(decoded.language == "sk")
        #expect(decoded.voiceProcessing == true)

        AnswerRecordingStore.deleteAll(directory: dir)
        #expect(AnswerRecordingStore.recordingCount(directory: dir) == 0)
    }
}

// MARK: - Batch flow on the shared mic engine

@Suite("#184 batch answer flow")
@MainActor
struct BatchAnswerFlowTests {
    private func makeVM(clock: AnyClock<Duration> = .continuous) -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService, MockAudioService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil,
            clock: clock
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        return (vm, silence, network, audio)
    }

    /// WHY: the whole point of #184 — ONE mic engine. The answer is captured
    /// off the listener's tap (voice-processed), never a second recorder.
    @Test("startRecording arms the capture on the shared engine, not AVAudioRecorder")
    func startArmsCaptureOnSharedEngine() async {
        let (vm, silence, _, audio) = makeVM()

        await vm.recordingCoordinator.startRecording()

        #expect(vm.quizState == .recording)
        #expect(silence.isListening, "the engine is started when nobody armed it")
        #expect(silence.isAnswerCaptureActive)
        #expect(audio.isRecording == false)
        #expect(vm.recordingCoordinator.startedListenerForAnswer, "this recording owns the engine it started")
    }

    /// WHY: the founder's core complaint — the recording must end on the
    /// on-device silence detector and reach the backend as WAV, and the sheet
    /// must show what the backend heard.
    @Test("VAD silence after speech ends the recording, uploads WAV, opens the sheet")
    func vadStopUploadsWav() async {
        let (vm, silence, network, _) = makeVM()
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 32000)) // 1 s of 16 kHz mono

        silence.simulateSilenceEvent(.speechStarted)
        silence.simulateSilenceEvent(.silenceAfterSpeech(duration: VADTuning.silenceHangoverSecs))

        await pumpUntil({ vm.showAnswerConfirmation }, "the VAD stop never reached the sheet")
        #expect(network.submitVoiceAnswerCallCount == 1)
        #expect(network.capturedVoiceAnswerFileName == "answer.wav")
        #expect(network.capturedVoiceAnswerBytes == WAVEncoder.headerSize + 32000)
        #expect(vm.transcribedAnswer == "Test")
        #expect(silence.isAnswerCaptureActive == false)
        #expect(silence.isListening == false, "an engine this recording started is released again")
    }

    /// WHY: the manual mic tap must not auto-stop on a thinking pause DIFFERENTLY
    /// from auto-record — both paths end on the same VAD (parity with the
    /// realtime path's server VAD the founder was used to).
    @Test("manual recording also ends on the VAD")
    func manualRecordingEndsOnVAD() async {
        let (vm, silence, network, _) = makeVM()
        vm.isAutoRecording = false
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 16000))

        silence.simulateSilenceEvent(.speechStarted)
        silence.simulateSilenceEvent(.silenceAfterSpeech(duration: 0.8))

        await pumpUntil({ network.submitVoiceAnswerCallCount == 1 }, "manual recording never submitted on VAD")
    }

    /// WHY: a listener the command window already armed belongs to the window —
    /// the recording must not tear it down when it ends.
    @Test("an engine armed by the command window is left running after the recording")
    func windowOwnedEngineSurvives() async {
        let (vm, silence, _, _) = makeVM()
        vm.quizMuteOverride = true // no read-back, so no TTS teardown of the listener
        await silence.startListening() // the window armed it
        await vm.recordingCoordinator.startRecording()
        #expect(vm.recordingCoordinator.startedListenerForAnswer == false)

        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()

        #expect(silence.isListening, "the window's engine is not ours to stop")
        #expect(silence.stopListeningCallCount == 0)
    }

    /// WHY: #77 degrade-to-buttons — a recognizer that cannot start must not
    /// take the mic button with it. The plain recorder is the safety net.
    @Test("no mic engine → the legacy recorder records instead")
    func legacyRecorderFallback() async {
        let (vm, silence, network, audio) = makeVM()
        silence.shouldFailSetup = true

        await vm.recordingCoordinator.startRecording()
        #expect(vm.quizState == .recording)
        #expect(audio.isRecording == true, "the plain recorder opened")
        #expect(silence.isAnswerCaptureActive == false)
        #expect(vm.recordingCoordinator.usesLegacyRecorder)

        await vm.recordingCoordinator.stopRecordingAndSubmit()
        #expect(network.capturedVoiceAnswerFileName == "answer.m4a")
        #expect(vm.recordingCoordinator.usesLegacyRecorder == false)
    }

    /// WHY: the realtime path is the founder's A/B switch — OFF must take the
    /// batch capture even when an STT service is wired, ON must stream.
    @Test("the realtime switch decides between streaming and the batch capture")
    func realtimeSwitch() async {
        for (enabled, expectStreaming) in [(false, false), (true, true)] {
            let silence = MockSilenceDetectionService()
            let audio = MockAudioService()
            let stt = MockElevenLabsSTTService()
            let vm = QuizViewModel(
                networkService: Fixtures.makeFullMockNetwork(),
                audioService: audio,
                persistenceStore: MockPersistenceStore(),
                silenceDetectionService: silence,
                sttService: stt,
                realtimeSTTEnabled: { enabled }
            )
            vm.currentSession = Fixtures.makeActiveSession()
            vm.currentQuestion = Fixtures.makeQuestion()
            vm.quizState = .askingQuestion

            await vm.recordingCoordinator.startRecording()

            #expect(vm.isStreamingSTT == expectStreaming, "realtimeSTTEnabled=\(enabled)")
            #expect(silence.isAnswerCaptureActive == !expectStreaming, "realtimeSTTEnabled=\(enabled)")
            vm.recordingCoordinator.cancelProcessing()
        }
    }
}

// MARK: - Read-back of the recognised voice answer (track D)

@Suite("#184 answer read-back on the confirmation sheet")
@MainActor
struct AnswerReadBackTests {
    private func makeVM() -> (QuizViewModel, MockSilenceDetectionService, MockNetworkService, MockAudioService) {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        let network = Fixtures.makeFullMockNetwork()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        return (vm, silence, network, audio)
    }

    /// WHY: the founder cannot read the sheet while driving — a mishearing
    /// must be audible before the 5 s auto-confirm starts, not after grading.
    @Test("a voice answer is read back; auto-confirm and the command window arm afterwards")
    func voiceAnswerIsReadBack() async {
        let (vm, silence, network, audio) = makeVM()
        audio.playbackDurationNs = 0
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 16000))

        var countdownWhilePlaying: Int?
        var ttsFlagWhilePlaying = false
        audio.onPlaybackStarted = {
            countdownWhilePlaying = vm.autoConfirmCountdown
            ttsFlagWhilePlaying = vm.isPlayingAnswerReadBack
        }

        await vm.recordingCoordinator.stopRecordingAndSubmit()

        #expect(vm.showAnswerConfirmation)
        await pumpUntil({ audio.playOpusCallCount == 1 }, "read-back never played")
        #expect(network.synthesizedTexts == ["Test"], "the recognised text is what gets spoken")
        #expect(ttsFlagWhilePlaying, "read-back counts as app TTS while it plays")
        #expect(countdownWhilePlaying == 0, "auto-confirm must not run under the read-back")

        await pumpUntil({ !vm.isPlayingAnswerReadBack }, "read-back never finished")
        #expect(vm.autoConfirmCountdown == Config.autoConfirmDelaySecs, "auto-confirm arms once the read-back is done")
    }

    /// WHY: mute wins everywhere TTS starts (#85) — and the sheet must still arm
    /// its countdown immediately, or a muted driver waits on nothing.
    @Test("muted: no read-back, auto-confirm arms at once")
    func mutedSkipsReadBack() async {
        let (vm, silence, network, _) = makeVM()
        vm.quizMuteOverride = true
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 16000))

        await vm.recordingCoordinator.stopRecordingAndSubmit()

        #expect(vm.showAnswerConfirmation)
        #expect(network.synthesizedTexts.isEmpty)
        #expect(vm.isPlayingAnswerReadBack == false)
        #expect(vm.autoConfirmCountdown == Config.autoConfirmDelaySecs)
    }

    /// WHY: the streaming path lands on the same sheet and must read back too.
    @Test("a committed streaming transcript is read back")
    func streamingTranscriptIsReadBack() async {
        let (vm, _, network, _) = makeVM()
        vm.quizState = .recording

        await vm.recordingCoordinator.handleCommittedTranscript("Paris")

        #expect(vm.showAnswerConfirmation)
        #expect(vm.transcribedAnswer == "Paris")
        await pumpUntil({ network.synthesizedTexts == ["Paris"] }, "the committed transcript was never spoken")
    }

    /// WHY: "again" spoken (or tapped) during the read-back must stop the app
    /// talking and free the command window — not leave a ghost TTS running.
    @Test("re-record during the read-back stops playback and clears the TTS flag")
    func rerecordCancelsReadBack() async {
        let (vm, silence, _, audio) = makeVM()
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
        await pumpUntil({ audio.playOpusCallCount == 1 }, "read-back never started")
        #expect(vm.isPlayingAnswerReadBack)

        vm.recordingCoordinator.rerecordAnswer()

        #expect(vm.isPlayingAnswerReadBack == false)
        await pumpUntil({ audio.stopPlaybackCallCount >= 1 }, "playback was not stopped")
        #expect(vm.recordingCoordinator.isReadingBackAnswer == false)
    }

    /// WHY (review finding on PR #182): the read-back task's cancellation exits
    /// do not clear the TTS flag — a quiz ended mid-read-back must not leave
    /// `isPlayingAnswerReadBack` latched, or the command window never re-arms
    /// and no voice command (not even "start") works until relaunch.
    @Test("ending the quiz mid-read-back clears the TTS flag")
    func quizEndMidReadBackClearsFlag() async {
        let (vm, silence, _, audio) = makeVM()
        audio.playbackDurationNs = 2_000_000_000 // long enough to still be playing
        await vm.recordingCoordinator.startRecording()
        silence.simulateAnswerAudio(Data(count: 16000))
        await vm.recordingCoordinator.stopRecordingAndSubmit()
        await pumpUntil({ audio.playOpusCallCount == 1 }, "read-back never started")
        #expect(vm.isPlayingAnswerReadBack)

        // The façade's phase-exit / full reset path (what end-quiz and Home run).
        vm.taskBag.cancelAll()
        vm.recordingCoordinator.reset()

        #expect(vm.isPlayingAnswerReadBack == false)
        #expect(vm.recordingCoordinator.isReadingBackAnswer == false)
        #expect(vm.isPlayingAnyTTS == false, "the command window must be free to re-arm")
    }

    /// WHY: founder 2026-09-21 — only a VOICE answer is read back. An MCQ tap
    /// (or typed text) goes straight through, no TTS.
    @Test("an MCQ tap never triggers a read-back")
    func mcqTapNotReadBack() async {
        let (vm, _, network, _) = makeVM()

        await vm.submitMCQAnswer(key: "A", value: "Test")

        #expect(network.synthesizedTexts.isEmpty)
        #expect(vm.isPlayingAnswerReadBack == false)
    }
}
