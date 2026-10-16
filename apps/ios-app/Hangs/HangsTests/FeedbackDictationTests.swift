//
//  FeedbackDictationTests.swift
//  HangsTests
//
//  #109 phase 3 — voice dictation in the feedback sheet, #208.8 record then
//  transcribe on the server. These tests encode WHY the behaviour matters:
//  - The transcript must APPEND to the editable note, in the quiz language the
//    sheet was opened with, and only once the recording stopped (a report is
//    built up across several dictations and typing).
//  - The recorded PCM must become the WAV attachment, holding EVERY dictation
//    on the sheet — the audio is the fallback when the transcript is wrong, so
//    a lost pass is a silent data-loss bug.
//  - A tap on Send while dictating must wait for the text, or the last spoken
//    words never reach the report.
//  - Dictation must auto-stop at the 120 s cap (the WAV cannot outgrow the
//    backend's audio guideline) and still transcribe what was said.
//  - The mic must stay BLOCKED while the quiz itself is recording — the single
//    shared AVAudioEngine can't serve both, and a second engine is the #64/#77
//    crash class.
//  - A denied mic permission must degrade to typing, never strand the sheet.
//

@preconcurrency import AVFoundation
import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing
import UIKit

@MainActor
private func makeVoiceFeedbackVM(
    network: MockNetworkService = MockNetworkService(),
    audio: MockAudioService = MockAudioService(),
    quizRecording: Bool = false,
    micGranted: Bool = true
) -> (FeedbackViewModel, MockNetworkService, MockAudioService) {
    audio.micPermissionResult = micGranted
    let voice = FeedbackVoiceServices(
        audioService: audio,
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
    return (vm, network, audio)
}

// .serialized is REQUIRED: every test here wraps its body in
// withMainSerialExecutor, which flips the *process-global*
// swift_task_enqueueGlobal_hook and restores it in a defer. Run in parallel
// (Swift Testing's default), sibling tests null that global hook mid-flight and
// destroy each other's serial-executor guarantee — reordering the
// transcription → @MainActor hops and starving the cap timer's post-wake hops
// past the poll deadline (the "cap never fires" flake).
// Same process-global reason NetworkServiceTests/AuthServiceTests/
// PackOrderServiceTests are .serialized.
@Suite("FeedbackViewModel Dictation", .serialized)
@MainActor
struct FeedbackDictationTests {
    // MARK: - Transcript append

    @Test("the transcript appends to the typed note after stop, in the sheet's language")
    func transcriptAppendsAfterStop() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM()
            network.dictationTranscript = "the timer kept counting"
            vm.message = "Bug:"

            await vm.startDictation()
            #expect(vm.isDictating)
            audio.emitStreamingChunk(dictationChunk)
            #expect(vm.message == "Bug:", "no text before the recording stops")

            await vm.stopDictation()

            #expect(vm.message == "Bug: the timer kept counting")
            #expect(network.capturedDictationUploads.map(\.language) == ["sk"])
            #expect(network.capturedDictationUploads.first?.bytes == 44 + 640)
        }
    }

    @Test("a failed transcription flags it and keeps the typed note as it was")
    func failedTranscriptionKeepsNote() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM()
            network.dictationError = NetworkError.invalidResponse
            vm.message = "typed part"

            await vm.startDictation()
            audio.emitStreamingChunk(dictationChunk)
            await vm.stopDictation()

            #expect(vm.didFailTranscription)
            #expect(vm.message == "typed part")
        }
    }

    // MARK: - Send waits for the text

    @Test("Send tapped while transcribing waits for the text and sends it with the WAV")
    func sendWaitsForTranscription() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM()
            let gate = DictationGate()
            network.dictationGate = { await gate.wait() }
            network.dictationTranscript = "the timer froze"

            await vm.startDictation()
            audio.emitStreamingChunk(dictationChunk)
            // Send while still dictating: the note is still empty at the tap.
            let sending = Task { await vm.send() }
            await pumpUntil({ vm.isTranscribing }, turns: 2000, "transcription never started")
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(network.submitFeedbackCallCount == 0, "sent before the dictated text arrived")

            await gate.open()
            await sending.value

            #expect(network.submitFeedbackCallCount == 1)
            #expect(network.capturedFeedbackMessage == "the timer froze")
            #expect(network.capturedFeedbackAudio?.count == 44 + 640)
        }
    }

    // MARK: - 120 s cap

    @Test("dictation auto-stops at the cap, flags why and still transcribes")
    func dictationHitsCap() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM()
            network.dictationTranscript = "and the planets"
            // The feedback sheet is NOT on the quiz clock seam (#180 track A):
            // its cap timer is a plain `Task.sleep`, so the shrunk cap is still
            // the only way to drive it.
            vm.maxDictationSeconds = 0.02

            await vm.startDictation()
            audio.emitStreamingChunk(dictationChunk)

            try? await Task.sleep(for: .milliseconds(150))
            await pumpUntil(
                { vm.micState == .idle && vm.message == "and the planets" },
                turns: 4000,
                "cap never auto-stopped and transcribed the dictation"
            )
            #expect(vm.didHitDictationCap == true)
            #expect(audio.audioEngineActive == false)
        }
    }

    // MARK: - Guard while quiz records

    @Test("mic is blocked and inert while the quiz itself is recording")
    func blockedWhileQuizRecording() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM(quizRecording: true)

            #expect(vm.isBlockedByQuizRecording == true)
            #expect(vm.micButtonDisabled == true)

            await vm.startDictation()

            // The single shared engine must never open here.
            #expect(vm.micState == .idle)
            #expect(audio.isRecording == false)
            #expect(audio.streamingChunkHandler == nil)
            #expect(network.capturedDictationUploads.isEmpty)
        }
    }

    // MARK: - Permission denied

    @Test("denied mic permission degrades to typing, never opens the engine")
    func deniedPermissionDegradesToTyping() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM(micGranted: false)

            await vm.startDictation()
            await vm.stopDictation()

            #expect(vm.micState == .denied)
            #expect(audio.isRecording == false)
            #expect(audio.streamingChunkHandler == nil)
            #expect(network.capturedDictationUploads.isEmpty)

            // Typing still works and can be sent.
            vm.message = "typed because mic is off"
            #expect(vm.canSend == true)
        }
    }

    // MARK: - Multi-pass audio (WAV must hold every pass)

    @Test("the WAV holds every dictation on the sheet, not just the last")
    func multiPassPCMAccumulates() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM()

            // Pass 1.
            network.dictationTranscript = "first"
            await vm.startDictation()
            audio.emitStreamingChunk(dictationChunk)
            await vm.stopDictation()

            // Pass 2, exactly as the UI invites ("Tap Dictate to add more"). Its
            // audio must be APPENDED, not replace pass 1's.
            network.dictationTranscript = "second"
            await vm.startDictation()
            audio.emitStreamingChunk(dictationChunk)
            await vm.stopDictation()

            #expect(vm.message == "first second")
            // Each pass is transcribed on its own (only its own audio is uploaded).
            #expect(network.capturedDictationUploads.map(\.bytes) == [44 + 640, 44 + 640])

            await vm.send()

            #expect(network.submitFeedbackCallCount == 1)
            let wav = network.capturedFeedbackAudio
            #expect(wav?.prefix(4) == Data("RIFF".utf8))
            // 44-byte RIFF header + BOTH 640-byte passes (1324), not just one (684).
            #expect(wav?.count == 44 + 640 + 640)
        }
    }

    // MARK: - Interruption releases the shared mic

    @Test("an audio-session interruption releases the shared mic and keeps what was said")
    func interruptionReleasesMic() async {
        await withMainSerialExecutor {
            let (vm, network, audio) = makeVoiceFeedbackVM()
            network.dictationTranscript = "before the call"

            await vm.startDictation()
            #expect(audio.audioEngineActive == true)
            audio.emitStreamingChunk(dictationChunk)

            // A phone call / Siri interrupts. The shared AudioService routes its own
            // callback to QuizViewModel, so the dictation's OWN observer must
            // fire and reset it — else micState stays stuck .dictating.
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )

            await pumpUntil(
                { vm.micState == .idle && vm.message == "before the call" },
                turns: 2000,
                "interruption never released the mic and transcribed"
            )
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
