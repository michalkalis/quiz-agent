//
//  TextDictationTests.swift
//  HangsTests
//
//  The shared "dictate into a text field" engine (custom-pack prompt, feedback,
//  rating). #208.8: record, then transcribe once on the server (OpenAI STT).
//  Why these tests matter:
//  - The text must land in the owner's field only after the recording stops,
//    in the language the owner asked for (the PACK language for the prompt):
//    a Czech topic transcribed as Slovak comes out garbled.
//  - The upload must be exactly the recorded PCM wrapped as WAV — a clip that
//    loses audio is a silent data-loss bug.
//  - A failed or empty transcription must say so and never touch the text the
//    user already has.
//  - The cap must stop the recording AND still transcribe it: the words spoken
//    before the cap are the user's input.
//  - The mic must stay blocked while the quiz holds it: one shared
//    AVAudioEngine, and a second one is the #64/#77 crash class.
//  - A denied permission must degrade to typing, never strand the form.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

/// One-shot async gate: `wait()` suspends until `open()`. Holds a mocked
/// transcription in flight deterministically (shared by the dictation suites).
actor DictationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// 320 samples of 16-bit PCM, as one tap chunk would deliver.
let dictationChunk = Data(repeating: 0xAB, count: 640)

@MainActor
private func makeDictation(
    quizRecording: Bool = false,
    micGranted: Bool = true
) -> (TextDictation, MockNetworkService, MockAudioService) {
    let audio = MockAudioService()
    audio.micPermissionResult = micGranted
    let network = MockNetworkService()
    let voice = FeedbackVoiceServices(
        audioService: audio,
        isQuizRecording: { quizRecording },
        languageCode: "en"
    )
    return (TextDictation(voice: voice, networkService: network), network, audio)
}

// .serialized: withMainSerialExecutor flips a process-global hook (see
// FeedbackDictationTests).
@Suite("TextDictation (order-pack prompt)", .serialized)
@MainActor
struct TextDictationTests {
    @Test("the text lands after stop, in the pack language, from exactly the recorded PCM")
    func textLandsAfterStopInPackLanguage() async {
        await withMainSerialExecutor {
            let (dictation, network, audio) = makeDictation()
            network.dictationTranscript = "  for kids "
            var prompt = "Space"

            await dictation.start(languageCode: "cs") { prompt = TextDictation.appending($0, to: prompt) }
            #expect(dictation.isDictating)
            audio.emitStreamingChunk(dictationChunk)
            audio.emitStreamingChunk(dictationChunk)

            // Nothing is sent or typed while the user is still speaking.
            #expect(network.capturedDictationUploads.isEmpty)
            #expect(prompt == "Space")

            await dictation.stop()

            #expect(dictation.micState == .idle)
            #expect(audio.audioEngineActive == false, "the shared mic must be released")
            #expect(network.capturedDictationUploads.count == 1)
            #expect(network.capturedDictationUploads.first?.language == "cs")
            // 44-byte RIFF header + both teed chunks.
            #expect(network.capturedDictationUploads.first?.bytes == 44 + 640 + 640)
            #expect(prompt == "Space for kids", "trimmed text joins the prompt with one space")
            #expect(dictation.didFailTranscription == false)
        }
    }

    @Test("an empty transcript flags the failure and leaves the text untouched")
    func emptyTranscriptFlagsFailure() async {
        await withMainSerialExecutor {
            let (dictation, network, audio) = makeDictation()
            network.dictationTranscript = "   "
            var prompt = "Space"

            await dictation.start(languageCode: "en") { prompt = TextDictation.appending($0, to: prompt) }
            audio.emitStreamingChunk(dictationChunk)
            await dictation.stop()

            #expect(dictation.didFailTranscription, "silence must not look like success")
            #expect(prompt == "Space")
            #expect(dictation.isTranscribing == false)
        }
    }

    @Test("a failed transcription flags the failure and leaves the text untouched")
    func failedTranscriptionFlagsFailure() async {
        await withMainSerialExecutor {
            let (dictation, network, audio) = makeDictation()
            network.dictationError = NetworkError.invalidResponse
            var prompt = "Space"

            await dictation.start(languageCode: "en") { prompt = TextDictation.appending($0, to: prompt) }
            audio.emitStreamingChunk(dictationChunk)
            await dictation.stop()

            #expect(dictation.didFailTranscription, "an offline/server error must be visible")
            #expect(prompt == "Space")
            #expect(dictation.isTranscribing == false)
            #expect(dictation.micButtonDisabled == false, "the user can simply try again")
        }
    }

    // WHY: the cap runs the stop from its own task; the words spoken up to the
    // cap are the user's input and must still be transcribed.
    @Test("the cap stops the recording and still transcribes it")
    func capStopsAndTranscribes() async {
        await withMainSerialExecutor {
            let (dictation, network, audio) = makeDictation()
            network.dictationTranscript = "and the planets"
            dictation.maxDictationSeconds = 0.02
            var prompt = ""

            await dictation.start(languageCode: "en") { prompt = TextDictation.appending($0, to: prompt) }
            audio.emitStreamingChunk(dictationChunk)

            try? await Task.sleep(for: .milliseconds(150))
            await pumpUntil(
                { dictation.micState == .idle && prompt == "and the planets" },
                turns: 4000,
                "cap never stopped and transcribed the dictation"
            )

            #expect(dictation.didHitDictationCap)
            #expect(audio.audioEngineActive == false)
            #expect(network.capturedDictationUploads.count == 1)
        }
    }

    @Test("the mic stays blocked while the quiz holds it")
    func blockedWhileQuizRecords() async {
        let (dictation, network, audio) = makeDictation(quizRecording: true)
        #expect(dictation.micButtonDisabled)
        await dictation.start(languageCode: "sk") { _ in Issue.record("no dictation while the quiz records") }
        await dictation.stop()
        #expect(dictation.micState == .idle)
        #expect(audio.streamingChunkHandler == nil, "the shared engine must never open here")
        #expect(network.capturedDictationUploads.isEmpty)
    }

    @Test("a denied permission leaves typing available, flags the mic and uploads nothing")
    func deniedPermission() async {
        let (dictation, network, audio) = makeDictation(micGranted: false)
        await dictation.start(languageCode: "sk") { _ in }
        await dictation.stop()
        #expect(dictation.micState == .denied)
        #expect(dictation.micButtonDisabled)
        #expect(audio.streamingChunkHandler == nil)
        #expect(network.capturedDictationUploads.isEmpty)
    }

    @Test("no shared voice services means no mic at all")
    func unavailableWithoutVoice() {
        #expect(!TextDictation(voice: nil, networkService: nil).isAvailable)
    }
}
