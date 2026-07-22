//
//  FeedbackDictationTests.swift
//  HangsTests
//
//  #109 phase 3 — voice dictation in the feedback sheet. These tests encode WHY
//  the behaviour matters:
//  - Committed transcript segments must APPEND to the editable note (a dictated
//    report is built up across VAD pauses); partials are shown live but not
//    committed.
//  - The teed PCM must become a non-empty WAV attachment — the audio is the
//    fallback when the transcript is wrong, so a dictation that sends no audio is
//    a silent data-loss bug.
//  - Dictation must auto-stop at the 120 s cap so a WAV can't grow past the
//    backend's audio guideline, and the UI can explain the stop.
//  - The mic must stay BLOCKED while the quiz itself is recording — the single
//    shared AVAudioEngine can't serve both, and a second engine is the #64/#77
//    crash class.
//  - A denied mic permission must degrade to typing, never strand the sheet.
//
//  Uses withMainSerialExecutor (ConcurrencyExtras) for deterministic Task
//  scheduling across the STT actor → AsyncStream → listener Task → @MainActor hops.
//

@preconcurrency import AVFoundation
import ConcurrencyExtras
import Foundation
import Testing
import UIKit
@testable import Hangs

@MainActor
private func makeVoiceFeedbackVM(
    network: MockNetworkService = MockNetworkService(),
    audio: MockAudioService = MockAudioService(),
    stt: MockElevenLabsSTTService = MockElevenLabsSTTService(),
    quizRecording: Bool = false,
    micGranted: Bool = true
) -> (FeedbackViewModel, MockNetworkService, MockAudioService, MockElevenLabsSTTService) {
    audio.micPermissionResult = micGranted
    let voice = FeedbackVoiceServices(
        audioService: audio,
        sttService: stt,
        isQuizRecording: { quizRecording },
        languageCode: "sk"
    )
    let vm = FeedbackViewModel(
        networkService: network,
        context: .none,
        screenshot: nil,
        voice: voice,
        logsProvider: { "logs" }
    )
    return (vm, network, audio, stt)
}

@MainActor
private func waitUntil(
    _ predicate: @MainActor () -> Bool,
    timeoutMillis: Int = 5_000,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMillis))
    while ContinuousClock.now < deadline {
        if predicate() { return }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
    if predicate() { return }
    Issue.record(comment ?? "waitUntil timed out after \(timeoutMillis)ms", sourceLocation: sourceLocation)
}

// .serialized is REQUIRED: every test here wraps its body in
// withMainSerialExecutor, which flips the *process-global*
// swift_task_enqueueGlobal_hook and restores it in a defer. Run in parallel
// (Swift Testing's default), sibling tests null that global hook mid-flight and
// destroy each other's serial-executor guarantee — reordering the STT actor →
// AsyncStream → @MainActor hops (committedSegments flake) and starving the cap
// timer's post-wake hops past the poll deadline (the "cap never fires" flake).
// Same process-global reason NetworkServiceTests/AuthServiceTests/
// PackOrderServiceTests are .serialized.
@Suite("FeedbackViewModel Dictation", .serialized)
@MainActor
struct FeedbackDictationTests {

    // MARK: - Transcript append

    @Test("committed segments append to the editable note; partials show live")
    func committedSegmentsAppend() async {
        await withMainSerialExecutor {
            let (vm, _, _, stt) = makeVoiceFeedbackVM()

            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "dictation never started")

            await stt.injectEvent(.partialTranscript("the ti..."))
            await waitUntil({ vm.partialTranscript == "the ti..." }, "partial never propagated")

            await stt.injectEvent(.committedTranscript("the timer"))
            await waitUntil({ vm.message == "the timer" }, "first committed segment never appended")
            // A committed segment clears the live partial.
            #expect(vm.partialTranscript == "")

            await stt.injectEvent(.committedTranscript("kept counting"))
            await waitUntil({ vm.message == "the timer kept counting" }, "second segment never appended with a separator")
        }
    }

    // MARK: - WAV tee

    @Test("teed PCM becomes a non-empty WAV attachment on send")
    func teedPCMBecomesWav() async {
        await withMainSerialExecutor {
            let (vm, network, audio, stt) = makeVoiceFeedbackVM()
            // Keep the forced stop-commit empty so it doesn't append surprise text.
            await stt.setMockCommittedText("")

            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "dictation never started")

            // Drive PCM chunks through the streaming handler, as the real tap would.
            let chunk = Data(repeating: 0xAB, count: 640) // 320 samples of 16-bit PCM
            audio.emitStreamingChunk(chunk)
            audio.emitStreamingChunk(chunk)

            await vm.stopDictation()
            await waitUntil({ !vm.isDictating }, "dictation never stopped")

            vm.message = "audio should be attached"
            await vm.send()

            #expect(network.submitFeedbackCallCount == 1)
            let wav = network.capturedFeedbackAudio
            #expect(wav != nil)
            // 44-byte RIFF header + the 1280 teed PCM bytes.
            #expect((wav?.count ?? 0) > 44)
            #expect(wav?.prefix(4) == Data("RIFF".utf8))
        }
    }

    // MARK: - 120 s cap

    @Test("dictation auto-stops at the cap and flags why")
    func dictationHitsCap() async {
        await withMainSerialExecutor {
            let (vm, _, _, _) = makeVoiceFeedbackVM()
            vm.maxDictationSeconds = 0.02 // drive the cap without waiting 120 s

            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "dictation never started")

            // Wait for the FULL settled state, not just the mic returning idle:
            // the cap handler sets `micState = .idle` and `didHitDictationCap`
            // across actor hops, so polling only `micState == .idle` and then
            // asserting the flag immediately raced the flag's write (green ~1/3).
            // Gating on both flags removes the ordering race deterministically.
            await waitUntil(
                { vm.micState == .idle && vm.didHitDictationCap },
                "cap never auto-stopped dictation and flagged why"
            )
            #expect(vm.didHitDictationCap == true)
            #expect(vm.micState == .idle)
        }
    }

    // MARK: - Guard while quiz records

    @Test("mic is blocked and inert while the quiz itself is recording")
    func blockedWhileQuizRecording() async {
        await withMainSerialExecutor {
            let (vm, _, audio, _) = makeVoiceFeedbackVM(quizRecording: true)

            #expect(vm.isBlockedByQuizRecording == true)
            #expect(vm.micButtonDisabled == true)

            await vm.startDictation()

            // The single shared engine must never open here.
            #expect(vm.micState == .idle)
            #expect(audio.isRecording == false)
            #expect(audio.streamingChunkHandler == nil)
        }
    }

    // MARK: - Permission denied

    @Test("denied mic permission degrades to typing, never opens the engine")
    func deniedPermissionDegradesToTyping() async {
        await withMainSerialExecutor {
            let (vm, _, audio, _) = makeVoiceFeedbackVM(micGranted: false)

            await vm.startDictation()

            #expect(vm.micState == .denied)
            #expect(audio.isRecording == false)
            #expect(audio.streamingChunkHandler == nil)

            // Typing still works and can be sent.
            vm.message = "typed because mic is off"
            #expect(vm.canSend == true)
        }
    }

    // MARK: - Multi-segment audio (WAV must hold every pass)

    @Test("PCM accumulates across dictation segments — the WAV holds every pass, not just the last")
    func multiSegmentPCMAccumulates() async {
        await withMainSerialExecutor {
            let (vm, network, audio, stt) = makeVoiceFeedbackVM()
            // Forced stop-commit stays empty so it doesn't append surprise text.
            await stt.setMockCommittedText("")

            let chunk = Data(repeating: 0xAB, count: 640) // 320 samples of 16-bit PCM

            // Segment 1 — first dictation pass.
            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "segment 1 never started")
            audio.emitStreamingChunk(chunk)
            await vm.stopDictation()
            await waitUntil({ !vm.isDictating }, "segment 1 never stopped")

            // Segment 2 — a second pass, exactly as the UI invites ("Tap Dictate to
            // add more"). Its audio must be APPENDED, not replace segment 1's.
            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "segment 2 never started")
            audio.emitStreamingChunk(chunk)
            await vm.stopDictation()
            await waitUntil({ !vm.isDictating }, "segment 2 never stopped")

            vm.message = "two-pass report"
            await vm.send()

            #expect(network.submitFeedbackCallCount == 1)
            let wav = network.capturedFeedbackAudio
            #expect(wav != nil)
            // 44-byte RIFF header + BOTH 640-byte segments (1324), not just one (684).
            #expect(wav?.count == 44 + 640 + 640)
        }
    }

    // MARK: - Socket drop releases the shared mic

    @Test("an unexpected STT disconnect releases the shared mic and resets to idle")
    func disconnectReleasesMic() async {
        await withMainSerialExecutor {
            let (vm, _, audio, stt) = makeVoiceFeedbackVM()

            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "dictation never started")
            #expect(audio.audioEngineActive == true)

            // The STT socket drops mid-dictation.
            await stt.injectEvent(.disconnected(nil))

            await waitUntil({ vm.micState == .idle }, "disconnect never reset micState")
            // The shared engine MUST be released — otherwise the next quiz recording
            // overwrites a still-live engine (the #64/#77 two-engine crash class).
            #expect(audio.audioEngineActive == false)
            #expect(vm.partialTranscript == "")
        }
    }

    // MARK: - Interruption releases the shared mic

    @Test("an audio-session interruption releases the shared mic and resets to idle")
    func interruptionReleasesMic() async {
        await withMainSerialExecutor {
            let (vm, _, audio, _) = makeVoiceFeedbackVM()

            await vm.startDictation()
            await waitUntil({ vm.isDictating }, "dictation never started")
            #expect(audio.audioEngineActive == true)

            // A phone call / Siri interrupts. The shared AudioService routes its own
            // callback to QuizViewModel, so the feedback sheet's OWN observer must
            // fire and reset it — else micState stays stuck .dictating.
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )

            await waitUntil({ vm.micState == .idle }, "interruption never reset micState")
            #expect(audio.audioEngineActive == false)
        }
    }

    // MARK: - Structural single-engine backstop

    @Test("the shared AudioService refuses a second concurrent streaming start")
    func rejectsSecondStreamingStart() async throws {
        let audio = MockAudioService()
        try await audio.startStreamingRecording { _ in }
        #expect(audio.audioEngineActive == true)
        // A second start while one is live must fail loud, never overwrite the engine.
        await #expect(throws: AudioError.self) {
            try await audio.startStreamingRecording { _ in }
        }
    }
}
