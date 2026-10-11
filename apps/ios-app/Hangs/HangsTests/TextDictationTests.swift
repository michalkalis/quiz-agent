//
//  TextDictationTests.swift
//  HangsTests
//
//  Voice input for the custom-pack topic (TestFlight feedback 2026-10-09).
//  Why these tests matter:
//  - Committed segments must land in the editable prompt, joined with a space,
//    so a topic spoken in several breaths reads as one sentence.
//  - Dictation must listen in the PACK language the user picked, not the quiz
//    language — a Czech topic transcribed as Slovak comes out garbled.
//  - The mic must stay blocked while the quiz holds it: one shared
//    AVAudioEngine, and a second one is the #64/#77 crash class.
//  - A denied permission must degrade to typing, never strand the form.
//

import ConcurrencyExtras
import Foundation
@testable import Hangs
import Testing

@MainActor
private func makeDictation(
    stt: MockElevenLabsSTTService = MockElevenLabsSTTService(),
    quizRecording: Bool = false,
    micGranted: Bool = true
) -> TextDictation {
    let audio = MockAudioService()
    audio.micPermissionResult = micGranted
    let voice = FeedbackVoiceServices(
        audioService: audio,
        sttService: stt,
        isQuizRecording: { quizRecording },
        languageCode: "en"
    )
    return TextDictation(voice: voice, networkService: MockNetworkService())
}

// .serialized: withMainSerialExecutor flips a process-global hook (see
// FeedbackDictationTests).
@Suite("TextDictation (order-pack prompt)", .serialized)
@MainActor
struct TextDictationTests {
    @Test("committed segments append to the prompt in the selected pack language")
    func segmentsAppendInPackLanguage() async {
        await withMainSerialExecutor {
            let stt = MockElevenLabsSTTService()
            let dictation = makeDictation(stt: stt)
            var prompt = "Space"

            await dictation.start(languageCode: "cs") { prompt = TextDictation.appending($0, to: prompt) }
            await pumpUntil({ dictation.isDictating }, turns: 2000, "dictation never started")
            #expect(await stt.lastConnectLanguageCode == "cs")

            await stt.injectEvent(.committedTranscript("for kids"))
            await pumpUntil({ prompt == "Space for kids" }, turns: 2000, "segment never appended")
            await stt.injectEvent(.committedTranscript("  and planets "))
            await pumpUntil({ prompt == "Space for kids and planets" }, turns: 2000, "second segment never appended")

            await stt.setMockCommittedText("")
            await dictation.stop()
            #expect(dictation.micState == .idle)
        }
    }

    // WHY: the cap fires mid-sentence (partial transcript pending). The cap task
    // runs the stop; if the stop cancels that same task, its final drain busy-spins
    // on the main actor and the forced-commit words never land.
    @Test("the cap stops dictation mid-sentence without losing the last words")
    func capKeepsTheLastWords_text() async {
        await withMainSerialExecutor {
            let stt = MockElevenLabsSTTService()
            // The forced commit answers late, as ElevenLabs does: only a drain
            // that really suspends lets the listener deliver it.
            await stt.setCommitEmitsNothing(true)
            let dictation = makeDictation(stt: stt)
            dictation.maxDictationSeconds = 0.02
            var prompt = ""
            await dictation.start(languageCode: "en") { prompt = TextDictation.appending($0, to: prompt) }
            await pumpUntil({ dictation.isDictating }, turns: 2000, "dictation never started")
            await stt.injectEvent(.partialTranscript("and the pla"))
            await pumpUntil({ dictation.partialTranscript == "and the pla" }, turns: 2000, "partial never arrived")

            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await stt.injectEvent(.committedTranscript("and the planets"))
            }
            try? await Task.sleep(for: .milliseconds(150))
            await pumpUntil({ dictation.micState == .idle }, turns: 4000, "cap never stopped dictation")

            #expect(dictation.didHitDictationCap)
            #expect(await !stt.commitRanCancelled, "stopping must not cancel the cap task that is running it")
            #expect(prompt == "and the planets", "the forced-commit words must survive the cap stop")
        }
    }

    @Test("the mic stays blocked while the quiz holds it")
    func blockedWhileQuizRecords() async {
        let dictation = makeDictation(quizRecording: true)
        #expect(dictation.micButtonDisabled)
        await dictation.start(languageCode: "sk") { _ in Issue.record("no dictation while the quiz records") }
        #expect(dictation.micState == .idle)
    }

    @Test("a denied permission leaves typing available and flags the mic")
    func deniedPermission() async {
        let dictation = makeDictation(micGranted: false)
        await dictation.start(languageCode: "sk") { _ in }
        #expect(dictation.micState == .denied)
        #expect(dictation.micButtonDisabled)
    }

    @Test("no shared voice services means no mic at all")
    func unavailableWithoutVoice() {
        #expect(!TextDictation(voice: nil, networkService: nil).isAvailable)
    }
}
