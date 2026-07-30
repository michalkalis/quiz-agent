//
//  AudioServiceTests.swift
//  HangsTests
//
//  Tests for AudioService recording validation and synchronization fixes.
//  These tests help prevent regression of the 28-byte recording bug.
//

import AVFoundation
import Foundation
@testable import Hangs
import Testing

// MARK: - AudioError Tests

@Suite("AudioError Tests")
struct AudioErrorTests {
    @Test("recordingTooShort error has correct description")
    func recordingTooShortErrorDescription() {
        let error = AudioError.recordingTooShort
        #expect(error.errorDescription == "Recording too short or empty")
    }

    @Test("all audio errors have descriptions")
    func allErrorsHaveDescriptions() {
        let errors: [AudioError] = [
            .noActiveRecording,
            .recordingFailed,
            .recordingTooShort,
            .playbackFailed,
            .permissionDenied,
            .invalidBase64,
            .deviceNotFound,
        ]

        for error in errors {
            #expect(error.errorDescription != nil, "Error \(error) should have a description")
        }
    }
}

// MARK: - PlaybackState Tests

@Suite("PlaybackState Tests")
struct PlaybackStateTests {
    @Test("idle state has no playback id")
    func idleStateNoPlaybackId() {
        let state = AudioService.PlaybackState.idle
        #expect(state.isIdle == true)
        #expect(state.playbackId == nil)
    }

    @Test("playing state has playback id")
    func playingStateHasId() {
        let id = UUID()
        let state = AudioService.PlaybackState.playing(id: id)
        #expect(state.isIdle == false)
        #expect(state.playbackId == id)
    }

    @Test("playback states are equatable")
    func statesAreEquatable() {
        let id1 = UUID()
        let id2 = UUID()

        #expect(AudioService.PlaybackState.idle == AudioService.PlaybackState.idle)
        #expect(AudioService.PlaybackState.playing(id: id1) == AudioService.PlaybackState.playing(id: id1))
        #expect(AudioService.PlaybackState.playing(id: id1) != AudioService.PlaybackState.playing(id: id2))
        #expect(AudioService.PlaybackState.idle != AudioService.PlaybackState.playing(id: id1))
    }
}

// MARK: - Playback Operation Overlap (#133 V12)

//
// `playOpusAudio` claimed `.playing(id:)` and only registered the continuation that
// resumes its caller much later, after the real suspension in `asset.load(.duration)`.
// A newer playback landing in that window found nothing to cancel, then replaced the
// registration — and the older caller's `for try await` waited on a stream nothing
// would ever feed. The 5-second stall timer could not rescue it either: it inspected
// `audioPlayer`, which by then belonged to the NEWER playback, so it saw "playing
// fine" and early-returned. The awaiting caller hung forever, so
// `playQuestionAudio`'s tail never ran: no thinking-time countdown, playing-TTS flags
// stuck true, `currentCommandScreen` nil — voice commands dead until app restart.
//
// The claim and the registration are now one step (`beginPlaybackOperation`), and
// every late caller resolves ITS OWN operation (`playbackContinuation(for:)`). Those
// seams are asserted directly here: instantiating AudioService touches no
// AVAudioSession (observers register in `setupAudioSession`), so the overlap
// bookkeeping is testable without a live AVPlayer. Driving real playback to the
// suspension point would need a controllable `asset.load` — left to on-device /
// regression coverage.
//

@Suite("Playback Operation Overlap")
@MainActor
struct PlaybackOperationOverlapTests {
    @Test("a superseded playback's caller is cancelled, never left waiting")
    func supersededOperationCancelsItsCaller() async throws {
        let service = AudioService()
        let older = UUID()
        let olderStream = service.beginPlaybackOperation(older)

        // Exactly what a newer playOpusAudio does: stop, then claim. Pre-fix the older
        // claim carried no continuation yet, so this cancelled nothing.
        await service.stopPlayback()
        let newer = UUID()
        _ = service.beginPlaybackOperation(newer)

        // The older caller must come back — with CancellationError, the documented
        // supersede semantics — rather than await a stream nobody will ever feed.
        await #expect(throws: CancellationError.self) {
            for try await _ in olderStream {}
        }
        #expect(service.playbackState == .playing(id: newer), "the newer playback stays the current operation")
    }

    @Test("an older playback unwinding late cannot strand the newer one")
    func lateRetractionLeavesNewerOperationIntact() async {
        let service = AudioService()
        let older = UUID()
        _ = service.beginPlaybackOperation(older)
        await service.stopPlayback()
        let newer = UUID()
        _ = service.beginPlaybackOperation(newer)

        service.endPlaybackOperation(older) // the older body's defer, running late

        #expect(
            service.playbackContinuation(for: newer) != nil,
            "the newer caller must still be cancellable — clearing the registration blindly is the mirror image of the bug"
        )
    }

    @Test("only the owning operation resolves the active continuation")
    func continuationLookupIsOwnershipGated() {
        let service = AudioService()
        let mine = UUID()
        _ = service.beginPlaybackOperation(mine)

        #expect(service.playbackContinuation(for: mine) != nil)
        #expect(
            service.playbackContinuation(for: UUID()) == nil,
            "a stale operation id must resolve to nothing — that is how late callbacks know to stand down"
        )
    }

    @Test("a claim is never observable without the handle that cancels it")
    func claimAlwaysCarriesItsHandle() {
        let service = AudioService()
        #expect(service.playbackState.isIdle)

        let id = UUID()
        _ = service.beginPlaybackOperation(id)

        // The whole defect was a window where this pair disagreed.
        #expect(service.playbackState.playbackId == id)
        #expect(service.playbackContinuation(for: id) != nil)
    }
}

// MARK: - Playback Stall Verdict (#133 V12)

@Suite("Playback Stall Verdict")
struct PlaybackStallVerdictTests {
    @Test("its own operation, never started playing → fail it")
    func ownOperationNotPlayingFails() {
        // The original purpose of the timer: a player that never reached .playing
        // within 5s is stalled and the caller must be released with an error.
        #expect(AudioService.shouldFailStalledPlayback(isCurrentOperation: true, playerIsPlaying: false))
    }

    @Test("its own operation, playing → leave it alone")
    func ownOperationPlayingIsIgnored() {
        // A TTS read longer than 5s is not a stall; failing here started the
        // thinking-timer mid-read while audio kept playing.
        #expect(!AudioService.shouldFailStalledPlayback(isCurrentOperation: true, playerIsPlaying: true))
    }

    @Test("a superseded operation never judges the newer playback")
    func supersededOperationIsIgnored() {
        // The V12 half: this timer belongs to a playback that was already cancelled.
        // Reading the live player instead let it early-return believing all was well.
        #expect(!AudioService.shouldFailStalledPlayback(isCurrentOperation: false, playerIsPlaying: true))
        #expect(!AudioService.shouldFailStalledPlayback(isCurrentOperation: false, playerIsPlaying: false))
    }
}

// MARK: - Audio Session Category Options (#104 founder decision)

//
// Reads back the option set that `setupAudioSession` applies, via the pure
// `AudioService.categoryOptions(for:)` helper. This deliberately does NOT
// instantiate a live session or call `setActive`/permission — that path is the
// suspected cause of the HangsTests hang on the simulator. Media Mode must NOT
// carry `.allowBluetoothHFP` — the car negotiates a Bluetooth SCO link the instant
// HFP is offered, which is what made the car flap into "phone call" mode on every
// question. This intentionally REPLACES the #59.3/RS-18 guard that asserted HFP in
// media (AirPods-mic users are routed to Call Mode instead — see the doc comment
// on `categoryOptions`).

@Suite("AudioSession Category Options")
struct AudioSessionCategoryOptionsTests {
    @Test("media mode excludes allowBluetoothHFP so the car never shows a call UI")
    func mediaModeExcludesHFP() throws {
        let media = try #require(AudioMode.forId("media"))
        let options = AudioService.categoryOptions(for: media)

        // #104: HFP in media was the bug — it made the car negotiate a Bluetooth SCO
        // link and show a "phone call" UI. Media Mode falls back to the built-in mic.
        #expect(!options.contains(.allowBluetoothHFP))
        // A2DP stays — output remains high-quality Bluetooth playback.
        #expect(options.contains(.allowBluetoothA2DP))
    }

    @Test("default mode is media — and it excludes HFP")
    func defaultModeIsMediaWithoutHFP() {
        // AudioMode.default is index 1 (media). If the default ever gains HFP again,
        // the car call-UI flap regresses — pin it here.
        #expect(AudioMode.default.id == "media")
        #expect(!AudioService.categoryOptions(for: .default).contains(.allowBluetoothHFP))
    }

    @Test("call mode includes both HFP and A2DP")
    func callModeIncludesHFPAndA2DP() throws {
        let call = try #require(AudioMode.forId("call"))
        let options = AudioService.categoryOptions(for: call)

        #expect(options.contains(.allowBluetoothHFP))
        #expect(options.contains(.allowBluetoothA2DP))
    }

    @Test("media and call carry distinct Bluetooth option sets")
    func mediaAndCallOptionsAreDistinct() throws {
        let media = try #require(AudioMode.forId("media"))
        let call = try #require(AudioMode.forId("call"))

        #expect(AudioService.categoryOptions(for: media) != AudioService.categoryOptions(for: call))
    }

    @Test("every mode ducks background audio")
    func everyModeDucksBackgroundAudio() {
        for mode in AudioMode.supportedModes {
            let options = AudioService.categoryOptions(for: mode)
            #expect(options.contains(.duckOthers), "\(mode.id) should duck others")
            #expect(options.contains(.defaultToSpeaker), "\(mode.id) should default to speaker")
        }
    }

    @Test("shouldSwapCategoryForTTS swaps in media (no HFP) and holds in call (HFP present)")
    func shouldSwapCategoryForTTSFollowsHFP() throws {
        let media = try #require(AudioMode.forId("media"))
        let call = try #require(AudioMode.forId("call"))

        // Media: no HFP to protect, so swapping to .playback per-utterance is safe
        // and buys back the ~6dB .playAndRecord attenuation.
        #expect(AudioService.shouldSwapCategoryForTTS(options: AudioService.categoryOptions(for: media)) == true)
        // Call: HFP must stay up for the whole quiz — swapping would flap the car's
        // Bluetooth SCO link on/off around every question.
        #expect(AudioService.shouldSwapCategoryForTTS(options: AudioService.categoryOptions(for: call)) == false)
    }
}

// MARK: - Streaming Start: Hardware-Format Settle Wait (#104)

//
// `startStreamingRecording` used to fail immediately when the hardware input
// format read 0 Hz / 0 ch — a transient state while an audio route settles (e.g.
// right after a Bluetooth connect/disconnect or a category switch). The retry
// policy (validity check + bounded poll) is factored into pure/injectable seams so
// it's testable without a live AVAudioEngine/AVAudioSession.

@Suite("Streaming Start Hardware Format Settle Wait")
struct StreamingHardwareFormatSettleWaitTests {
    @Test("a positive sample rate and channel count is valid")
    func validFormatPasses() {
        #expect(AudioService.isValidHardwareFormat(sampleRate: 48000, channelCount: 1))
    }

    @Test("zero sample rate or zero channel count is invalid")
    func zeroFormatFails() {
        #expect(!AudioService.isValidHardwareFormat(sampleRate: 0, channelCount: 1))
        #expect(!AudioService.isValidHardwareFormat(sampleRate: 48000, channelCount: 0))
    }

    @Test("settles on the 3rd read: invalid, invalid, valid")
    func settlesOnThirdRead() async throws {
        var reads: [(sampleRate: Double, channelCount: AVAudioChannelCount)] = [
            (0, 0), (0, 0), (48000, 1),
        ]

        let outcome = try await AudioService.waitForValidHardwareFormat(
            readFormat: { reads.removeFirst() },
            sleep: { _ in } // no real delay in tests
        )

        #expect(outcome == .success(attempts: 3))
    }

    @Test("never settling times out rather than retrying forever")
    func neverSettlesTimesOut() async throws {
        let outcome = try await AudioService.waitForValidHardwareFormat(
            intervalMs: 150,
            timeoutMs: 300,
            readFormat: { (0, 0) },
            sleep: { _ in }
        )

        #expect(outcome == .timeout)
    }

    // The settle wait suspends with `audioEngine` still nil, so a teardown in that
    // window must invalidate the in-flight start (or the engine would come up AFTER
    // the stop and leave the mic hot in the background). The start compares
    // `streamingGeneration` after the wait; the stop must therefore bump it even
    // when no engine is live. Instantiating AudioService touches no AVAudioSession
    // (observers register in setupAudioSession, which this test never calls).
    @Test("stopStreamingRecording invalidates an in-flight start even with no live engine")
    @MainActor
    func stopWithoutEngineBumpsGeneration() {
        let service = AudioService()
        let generationBefore = service.streamingGeneration

        service.stopStreamingRecording()

        #expect(service.streamingGeneration == generationBefore + 1)
    }
}

// MARK: - Interruption Teardown Routing (#67 Part A / task 77.2)

//
// The bug: `handleInterruption(.began)` (a phone call) only ever called the
// *batch* `stopRecording()`. When the streaming PCM path was live, the batch
// stop never tore down its AVAudioEngine, so the recording was stranded after
// the call. The fix routes a live streaming engine to `stopStreamingRecording()`
// and notifies the owner (QuizViewModel) to leave `.recording`.
//
// The real streaming engine can't be started headlessly (empty supportedLocales /
// 0 Hz input on the Simulator — the documented CI audio blind spot), so the
// routing DECISION is factored into the pure `AudioService.interruptionTeardown`
// and asserted directly; MockAudioService drives that same function for the
// state-teardown + owner-notification contract, and a QuizViewModel test proves
// the end-to-end recovery.

@Suite("Interruption Teardown Routing")
struct InterruptionTeardownRoutingTests {
    @Test("streaming engine live routes to streaming teardown (the #67 bug case)")
    func streamingLiveRoutesToStreaming() {
        // Streaming path: audioEngine != nil AND isRecording. Before the fix this
        // fell to the batch stop, which never stopped the engine.
        #expect(AudioService.interruptionTeardown(isStreaming: true, isRecording: true) == .streaming)
    }

    @Test("batch recording (no streaming engine) routes to batch teardown")
    func batchRoutesToBatch() {
        #expect(AudioService.interruptionTeardown(isStreaming: false, isRecording: true) == .batch)
    }

    @Test("idle (no recording) tears down nothing")
    func idleRoutesToNone() {
        #expect(AudioService.interruptionTeardown(isStreaming: false, isRecording: false) == .none)
    }
}

// MARK: - Interruption Resume Routing (#100.3)

//
// The bug: `handleInterruption(.ended)` only logged ("don't auto-resume") and
// never reactivated the audio session. After a phone call / Siri interruption
// ended, a mic tap on the same question ran against a session iOS had
// deactivated, and `engine.start()`/`record()` failed with "Recording failed" —
// repeatable until a TTS replay happened to reactivate the session. The fix
// reactivates on `.ended` when the system reports `.shouldResume`. The decision
// is factored into the pure `AudioService.shouldResumeSession` (asserted
// directly, mirroring `interruptionTeardown` above); MockAudioService drives
// that same function to prove the state-machine effect: a mic tap fails while
// the session is inactive and succeeds again only after a resumable `.ended`.

@Suite("Interruption Resume Routing")
struct InterruptionResumeRoutingTests {
    @Test(".shouldResume present resumes the session")
    func shouldResumePresentResumes() {
        #expect(AudioService.shouldResumeSession(options: [.shouldResume]) == true)
    }

    @Test("no .shouldResume option does not resume")
    func noShouldResumeDoesNotResume() {
        #expect(AudioService.shouldResumeSession(options: []) == false)
    }
}

// MARK: - MockAudioService Interruption Contract (#67 Part A)

@Suite("MockAudioService Interruption Contract")
@MainActor
struct MockAudioServiceInterruptionTests {
    @Test("interruption during streaming stops the engine, clears isRecording, and notifies the owner")
    func interruptionDuringStreamingTearsDownAndNotifies() async throws {
        let service = MockAudioService()
        var notified = false
        service.onInterruptionBegan = { notified = true }

        // Enter the streaming state (engine live, recording).
        try await service.startStreamingRecording { _ in }
        #expect(service.isRecording == true)
        #expect(service.audioEngineActive == true)

        service.simulateInterruptionBegan()

        // audioEngine == nil, isRecording == false, owner notified.
        #expect(service.audioEngineActive == false)
        #expect(service.isRecording == false)
        #expect(notified == true)
    }

    @Test("interruption while not recording notifies nobody and stays idle")
    func interruptionWhileIdleIsNoOp() {
        let service = MockAudioService()
        var notified = false
        service.onInterruptionBegan = { notified = true }

        service.simulateInterruptionBegan()

        #expect(service.isRecording == false)
        #expect(notified == false)
    }

    // #100.3: the actual "mic does not recover" regression. Without the fix,
    // `.ended` never reactivates the session, so `startStreamingRecording`
    // keeps failing on the same question until something else (a TTS replay)
    // reactivates it — the loop dead-ends on "Recording failed".
    @Test("a resumable .ended reactivates the session so the next mic tap succeeds")
    func resumableEndedReactivatesSessionForNextRecording() async throws {
        let service = MockAudioService()

        // Phone call arrives mid-recording: system deactivates the session,
        // streaming teardown fires.
        try await service.startStreamingRecording { _ in }
        service.simulateInterruptionBegan()
        #expect(service.isRecording == false)

        // A mic tap in the gap between call-ends and session-reactivation must
        // fail loud, not silently misbehave.
        await #expect(throws: AudioError.recordingFailed) {
            try await service.startStreamingRecording { _ in }
        }

        // Call ends with .shouldResume (the common case for phone calls).
        service.simulateInterruptionEnded(options: [.shouldResume])

        // Next mic tap on the same question now succeeds — no TTS replay needed.
        try await service.startStreamingRecording { _ in }
        #expect(service.isRecording == true)
    }

    @Test("an .ended without .shouldResume leaves the session inactive")
    func endedWithoutShouldResumeStaysInactive() async throws {
        let service = MockAudioService()

        try await service.startStreamingRecording { _ in }
        service.simulateInterruptionBegan()

        service.simulateInterruptionEnded(options: [])

        await #expect(throws: AudioError.recordingFailed) {
            try await service.startStreamingRecording { _ in }
        }
    }
}

// MARK: - QuizViewModel Interruption Recovery (#67 Part A)

@Suite("QuizViewModel Interruption Recovery")
@MainActor
struct QuizViewModelInterruptionTests {
    @Test("a phone-call interruption during streaming leaves .recording and resets streaming state")
    func interruptionDuringStreamingLeavesRecording() async throws {
        let mockAudio = MockAudioService()
        let viewModel = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: mockAudio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: MockSilenceDetectionService(),
            sttService: nil
        )
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()

        // Simulate an active streaming recording.
        viewModel.quizState = .recording
        viewModel.isStreamingSTT = true
        try await mockAudio.startStreamingRecording { _ in }
        #expect(mockAudio.isRecording == true)

        // Phone call arrives → AudioService fires onInterruptionBegan (wired in init).
        mockAudio.simulateInterruptionBegan()

        // VM left .recording; audio + streaming state reset — no stranded recording.
        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.isStreamingSTT == false)
        #expect(mockAudio.isRecording == false)
        #expect(mockAudio.audioEngineActive == false)
    }
}

// MARK: - Integration Test Notes

//
// The following tests require a real device or simulator with microphone access.
// They are marked as requiring explicit running since they need hardware.
//
// To run these tests:
// 1. Open Xcode
// 2. Select an iOS Simulator destination
// 3. Run tests (Cmd+U)
// 4. Grant microphone permission when prompted
//
// Manual verification steps:
// 1. Recording produces >500 bytes: Check console for "Recording data: X bytes"
// 2. Playback-to-recording transition works: Start quiz, tap record during audio
// 3. Interruptions handled: Trigger Siri during recording, verify graceful stop
// 4. Rapid double-tap microphone: Should not crash or start duplicate recordings
// 5. Start playback, immediately tap record: Clean state transition to recording
