//
//  RecordingFeedbackTests.swift
//  HangsTests
//
//  #185 track F (car test 2026-09-23, finding 4b; founder pick F2 "Lišta
//  dýcha"): while the driver answers, the question screen's listen bar must say
//  which phase the recording is in — "Listening…" → "Capturing…" →
//  "Processing…" — and glow with the live mic level, and a gentle tone must mark
//  the moment speech is first heard. In the car nothing on screen said whether
//  the mic heard anything at all, so the driver could not tell a deaf detector
//  from a slow backend.
//

import Clocks
import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

// MARK: - The bar: status text per phase + layout

@Suite("#185 F — listen bar status per recording phase")
@MainActor
struct ListenBarRecordingStatusTests {
    private func host(
        _ bar: ListenBar,
        _ assertions: (InspectableView<ViewType.ClassifiedView>) throws -> Void
    ) async throws {
        try await ViewHosting.host(bar) { try assertions(bar.inspect()) }
    }

    /// WHY: before any speech the driver needs the instruction AND the fact
    /// that the mic is open — the status says the second, the caption the first.
    @Test("waiting for speech: \"Listening…\" over the instruction")
    func listening() async throws {
        try await host(ListenBar(mode: .answer(.open))) { tree in
            #expect(throws: Never.self) { try tree.find(text: "Listening…") }
            #expect(throws: Never.self) { try tree.find(text: "Say your answer") }
            #expect(throws: (any Error).self, "no speech was heard yet") {
                try tree.find(text: "Capturing…")
            }
        }
    }

    /// WHY: the car finding — the driver could not tell whether the mic heard
    /// him. Once speech is detected the bar must SAY so, and say how it ends,
    /// so nobody keeps talking to fill a silence the app is waiting for.
    @Test("speech heard: \"Capturing…\" and how the recording will end")
    func capturing() async throws {
        try await host(ListenBar(mode: .answer(.mcq), speechHeard: true)) { tree in
            #expect(throws: Never.self) { try tree.find(text: "Capturing…") }
            #expect(throws: Never.self) { try tree.find(text: "I'll stop when you go quiet") }
            #expect(throws: (any Error).self, "the status must move on, not stack") {
                try tree.find(text: "Listening…")
            }
        }
    }

    /// WHY: the Stop button and the bar say the same word while the answer is
    /// in flight — two different words read as two different things happening.
    @Test("in flight: \"Processing…\", spinning, nothing to say")
    func processing() async throws {
        try await host(ListenBar(mode: .evaluating)) { tree in
            #expect(throws: Never.self) { try tree.find(text: "Processing…") }
            #expect(throws: Never.self) { try tree.find(text: "No need to say anything") }
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.spinner")
            }
        }
    }

    /// WHY: `speechHeard` is an answer-mode fact — a stale flag must never make
    /// a closed mic claim it is capturing.
    @Test("a stale speech flag cannot make the in-flight bar claim it is capturing")
    func speechFlagIgnoredOutsideAnswerMode() async throws {
        try await host(ListenBar(mode: .evaluating, speechHeard: true)) { tree in
            #expect(throws: (any Error).self) { try tree.find(text: "Capturing…") }
        }
    }

    /// WHY: F2's large status lives only where the recording is — the command
    /// states keep their chips layout, and the SE-class slim bar has no room
    /// for two lines. The taller bar is the price the MCQ grid pays only while
    /// an answer is in flight, so it must stay limited to those states.
    @Test("the 58pt status layout is used only by the answer and in-flight states")
    func statusLayoutScope() {
        #expect(ListenBar(mode: .answer(.open)).usesStatusLayout)
        #expect(ListenBar(mode: .answer(.mcq), onDismiss: {}).usesStatusLayout)
        #expect(ListenBar(mode: .evaluating).usesStatusLayout)
        #expect(ListenBar(mode: .skipping).usesStatusLayout)
        #expect(!ListenBar(mode: .command).usesStatusLayout)
        #expect(!ListenBar(mode: .readingQuestion).usesStatusLayout)
        #expect(!ListenBar(mode: .answer(.open), size: .slim).usesStatusLayout)
        #expect(ListenBar.statusHeight == 58)
        #expect(ListenBar.statusHeight > ListenBar.height(size: .full, hasSubLine: true),
                "the status bar is the larger, glanceable one")
    }
}

// MARK: - Level → glow

@Suite("#185 F — the bar breathes with the mic level")
@MainActor
struct ListenBarGlowMappingTests {
    typealias Glow = ListenBarLevelGlow.Glow

    /// WHY: a quiet mic is still an OPEN mic — the ring must be visible at
    /// zero, or "the mic hears nothing" and "the mic is closed" look the same.
    @Test("a silent open mic still glows faintly")
    func quietStillGlows() {
        let quiet = Glow.forLevel(0)
        #expect(quiet.ringWidth > 0)
        #expect(quiet.haloOpacity > 0)
    }

    /// WHY: the whole point — a louder voice must visibly swell the bar, and
    /// never shrink it, or the glow tells the driver nothing about being heard.
    @Test("louder input swells the ring and brightens the halo, monotonically")
    func monotonic() {
        let levels = stride(from: 0.0, through: 1.0, by: 0.1).map(Glow.forLevel)
        for (a, b) in zip(levels, levels.dropFirst()) {
            #expect(b.ringWidth > a.ringWidth)
            #expect(b.haloOpacity > a.haloOpacity)
            #expect(b.haloRadius > a.haloRadius)
        }
        #expect(Glow.forLevel(1).ringWidth >= 3 * Glow.forLevel(0).ringWidth,
                "speech must read clearly from the corner of the eye")
    }

    /// WHY: the level is dB above a noise floor and can overshoot; a clipped
    /// map keeps a shout from blowing the ring over the question text.
    @Test("out-of-range levels are clamped")
    func clamped() {
        #expect(Glow.forLevel(-0.5) == Glow.forLevel(0))
        #expect(Glow.forLevel(3) == Glow.forLevel(1))
    }
}

// MARK: - Level smoothing

@Suite("#185 F — mic level smoothing")
@MainActor
struct RecordingInputLevelTests {
    /// WHY: the glow must jump with a syllable but fade between words — a
    /// symmetric filter either lags the voice or flickers at every consonant.
    @Test("fast attack, slow release")
    func attackFasterThanRelease() {
        let rise = RecordingInputLevel.smoothed(previous: 0, sample: 1)
        let fall = 1 - RecordingInputLevel.smoothed(previous: 1, sample: 0)
        #expect(rise > fall, "rising by \(rise) must outpace falling by \(fall)")
    }

    /// WHY: a silent mic must settle on the quiet ring, not hover a hair above.
    @Test("the tail snaps to zero")
    func tailSnapsToZero() {
        var level = 1.0
        for _ in 0 ..< 60 { level = RecordingInputLevel.smoothed(previous: level, sample: 0) }
        #expect(level == 0)
    }

    /// WHY: ~47 samples a second — an invisible wobble must not cost a render.
    @Test("changes below the threshold are not published; reset returns to zero")
    func thresholdAndReset() {
        let meter = RecordingInputLevel()
        meter.ingest(0.01)
        #expect(meter.level == 0, "a 0.6 % move is not worth a redraw")
        meter.ingest(0.8)
        #expect(meter.level > 0.4)
        meter.reset()
        #expect(meter.level == 0)
    }
}

// MARK: - View model: level feed, speech flag, speech-start tone

@Suite("#185 F — recording feedback from the answer pipeline")
@MainActor
struct RecordingFeedbackPipelineTests {
    private func makeVM() -> (QuizViewModel, MockSilenceDetectionService, MockEarconPlayer) {
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: Fixtures.makeFullMockNetwork(),
            audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            sttService: nil,
            clock: AnyClock(TestClock())
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .askingQuestion
        let earcons = MockEarconPlayer()
        vm.earconPlayer = earcons
        return (vm, silence, earcons)
    }

    private func loud() -> InputLevel { InputLevel(db: -20, noiseFloorDb: -50) } // 1.0

    /// WHY: the glow is the answer to "does the mic hear me?" — the engine's
    /// level must reach the bar while recording, and stop when it ends: a bar
    /// glowing over a closed mic would be a lie.
    @Test("the mic level reaches the bar while recording and resets when it stops")
    func levelFeedFollowsTheRecording() async {
        let (vm, silence, _) = makeVM()
        await vm.recordingCoordinator.startRecording()
        #expect(vm.quizState == .recording)

        silence.simulateInputLevel(loud())
        await pumpUntil({ vm.recordingInputLevel.level > 0.5 }, "the level never reached the bar")

        await vm.recordingCoordinator.stopRecordingAndSubmit()
        #expect(vm.recordingInputLevel.level == 0, "a stopped recording must not keep glowing")
    }

    /// WHY: the engine's level flows during command windows too (~47 Hz while
    /// it runs) — only an answer recording may drive the glow.
    @Test("levels outside a recording never move the bar")
    func noGlowOutsideRecording() async {
        let (vm, silence, _) = makeVM()
        await vm.recordingCoordinator.startRecording()
        vm.quizState = .askingQuestion // e.g. a teardown that has not cancelled the feed yet

        silence.simulateInputLevel(loud())
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(vm.recordingInputLevel.level == 0)
    }

    /// WHY: "Zachytávam…" is the car finding's answer — it must flip exactly
    /// when the detector hears speech, not before.
    @Test("speech detection flips the bar to capturing")
    func speechFlipsToCapturing() async {
        let (vm, silence, _) = makeVM()
        await vm.recordingCoordinator.startRecording()
        #expect(!vm.isHearingAnswer, "nothing was said yet")

        silence.simulateSilenceEvent(.speechStarted)
        await pumpUntil({ vm.isHearingAnswer }, "speech never reached the bar")
    }

    /// WHY (founder 2026-09-24): ONE gentle tone when speech starts. The
    /// streaming path reports speech on every partial transcript, so without
    /// the once-per-recording gate the driver would hear a tone per word.
    @Test("the speech-start tone plays once per recording")
    func speechStartToneOnce() async {
        let (vm, _, earcons) = makeVM()
        await vm.recordingCoordinator.startRecording()
        earcons.reset()

        vm.recordingCoordinator.noteSpeechStarted()
        vm.recordingCoordinator.noteSpeechStarted()
        vm.recordingCoordinator.noteSpeechStarted()

        #expect(earcons.played == [.speechStart])
    }

    /// WHY (founder 2026-09-25): "Recording sounds" off means SILENT, not
    /// unconfirmed — the tones go, the haptics for mic open / speech heard /
    /// mic closed stay, so the driver still feels each step.
    @Test("recording sounds off: no tones, but start / speech / stop still tap")
    func soundsOffKeepsRecordingHaptics() async {
        let (vm, _, earcons) = makeVM()
        vm.settings.recordingSoundsEnabled = false
        await vm.recordingCoordinator.startRecording()
        vm.recordingCoordinator.noteSpeechStarted()
        await vm.recordingCoordinator.stopRecordingAndSubmit()

        #expect(earcons.played.isEmpty, "no tone may play, got \(earcons.played)")
        #expect(earcons.hapticsOnly == [.micLive, .speechStart, .gotIt])
    }
}
