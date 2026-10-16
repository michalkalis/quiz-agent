//
//  VoiceCommandTimelineTests.swift
//  HangsTests
//
//  #208.7 (founder, TF 2026-10-16): "from the moment I start saying a command
//  it should show it hears me, and then that it's processing. Now I wait
//  ~1-2 s after a command before the app reacts." Two layers:
//  • the detector's speech edges (`SpeechActivityEvent`) — real service, audio
//    time on a TestClock, 20 ms buffers;
//  • the bar's timeline they drive: hearing → processing → ✓ (`.matched`).
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private final class EdgeBox {
    var events: [SpeechActivityEvent] = []
    var began: Int { events.filter { if case .began = $0 { true } else { false } }.count }
    var paused: Int { events.filter { if case .paused = $0 { true } else { false } }.count }
    var ended: Int { events.filter { $0 == .ended }.count }
    var resumed: Int { events.filter { $0 == .resumed }.count }
}

@MainActor
private func feed(_ service: SilenceDetectionService, _ clock: TestClock<Duration>, db: Float, seconds: Double) async {
    for _ in 0 ..< Int((seconds / 0.02).rounded()) {
        service.handleInputLevel(InputLevelSample(db: db, duration: 0.02))
        await clock.advance(by: .milliseconds(20))
    }
}

@Suite("#208.7 speech edges + the bar's hearing → processing → matched timeline")
@MainActor
struct VoiceCommandTimelineTests {
    private static var retained: [QuizViewModel] = []

    // MARK: - Detector edges (real service)

    private func makeService() -> (SilenceDetectionService, TestClock<Duration>, EdgeBox) {
        let clock = TestClock()
        let service = SilenceDetectionService(clock: AnyClock(clock))
        let box = EdgeBox()
        let stream = service.makeSpeechActivityStream()
        Task { for await event in stream {
            box.events.append(event)
        } }
        return (service, clock, box)
    }

    /// WHY: "hearing" must light while the first syllable is still in the air —
    /// within the onset hold (60 ms of 20 ms buffers), not after a recognizer
    /// hypothesis (~1.1 s median in the field).
    @Test("onset: .began on the buffer that completes the 60 ms hold, never before")
    func onsetWithinTheHold() async {
        let (service, clock, box) = makeService()
        await feed(service, clock, db: -50, seconds: 0.3) // calibrate the cabin floor
        await feed(service, clock, db: -35, seconds: 0.04)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(box.began == 0, "two buffers is a click, not speech")
        await feed(service, clock, db: -35, seconds: 0.02)
        await pumpUntil({ box.began == 1 }, "the third loud buffer must raise .began")
        guard case let .began(level, floor) = box.events.first else { return }
        #expect(level == -35)
        #expect(floor != nil, "the log needs the floor the onset was judged against")
    }

    /// WHY: "processing" keys off the level dropping, not off the 0.8 s hangover
    /// that ends an answer — that second is exactly the wait the founder felt.
    @Test("release raises .paused at once, a return .resumed, the hangover .ended")
    func pauseResumeEnd() async {
        let (service, clock, box) = makeService()
        await feed(service, clock, db: -50, seconds: 0.3)
        await feed(service, clock, db: -30, seconds: 0.4)
        await feed(service, clock, db: -50, seconds: 0.02)
        await pumpUntil({ box.paused == 1 }, "the first quiet buffer must raise .paused")
        guard case let .paused(speechSecs, peak) = box.events.last else { return }
        #expect(speechSecs >= 0.3, "the speech before the pause, for the blip bar")
        #expect(peak == -30)

        await feed(service, clock, db: -30, seconds: 0.1)
        await pumpUntil({ box.resumed == 1 }, "speech back inside the hangover is the same utterance")
        await feed(service, clock, db: -50, seconds: 1.0)
        await pumpUntil({ box.ended == 1 }, "the hangover must end the utterance")
    }

    /// WHY: with the listener kept up through the read, the app's own voice
    /// must neither raise edges nor leave the detector "speaking" — the
    /// driver's first word after the read must still raise a fresh .began.
    @Test("suspended for the read: echo raises nothing; the first word after it raises .began")
    func suspendedReadRaisesNothing() async {
        let (service, clock, box) = makeService()
        await feed(service, clock, db: -50, seconds: 0.3)
        service.suspendSpeechEdges(true)
        await feed(service, clock, db: -25, seconds: 2.0) // the question, leaking through
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(box.events.isEmpty, "the app's voice is not the driver")
        service.suspendSpeechEdges(false)
        await feed(service, clock, db: -50, seconds: 0.1)
        await feed(service, clock, db: -35, seconds: 0.06)
        await pumpUntil({ box.began == 1 }, "the cabin floor survived the read; the word is heard")
    }

    // MARK: - Bar timeline (coordinator)

    private func make() -> (QuizViewModel, VoiceCommandCoordinator, MockSilenceDetectionService, TestClock<Duration>) {
        let clock = TestClock()
        let silence = MockSilenceDetectionService()
        let vm = QuizViewModel(
            networkService: MockNetworkService(), audioService: MockAudioService(),
            persistenceStore: MockPersistenceStore(), silenceDetectionService: silence,
            clock: AnyClock(clock)
        )
        vm.quizState = .askingQuestion
        Self.retained.append(vm)
        vm.voiceCommandCoordinator.startCommandConsumer()
        return (vm, vm.voiceCommandCoordinator, silence, clock)
    }

    private var isProcessing: (VoiceCommandCoordinator) -> Bool {
        { $0.voiceFeedbackPhase == .recognizing && $0.recognizingCommand == nil }
    }

    /// WHY: the founder's timeline, end to end — start speaking → hearing,
    /// stop → processing (after a 250 ms hold so a breath does not flip it),
    /// the command lands → ✓.
    @Test("began → hearing; paused + 250 ms → processing; the final match → matched")
    func fullTimeline() async {
        let (_, coordinator, silence, clock) = make()
        silence.simulateSpeechActivity(.began(levelDb: -30, noiseFloorDb: -50))
        await pumpUntil({ coordinator.voiceFeedbackPhase == .hearing }, "onset must light hearing")

        silence.simulateSpeechActivity(.paused(speechSecs: 0.5, peakDb: -28))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await clock.advance(by: .milliseconds(249))
        #expect(coordinator.voiceFeedbackPhase == .hearing, "a breath inside a word must not say processing")
        await clock.advance(by: .milliseconds(1))
        await pumpUntil({ self.isProcessing(coordinator) }, "silence after a word must say processing")

        await coordinator.handleCommandTranscript(CommandTranscript(text: "repeat", isFinal: true))
        #expect(coordinator.voiceFeedbackPhase == .matched)
    }

    @Test("speech coming back inside the hold keeps hearing")
    func resumeCancelsProcessing() async {
        let (_, coordinator, silence, clock) = make()
        silence.simulateSpeechActivity(.began(levelDb: -30, noiseFloorDb: -50))
        silence.simulateSpeechActivity(.paused(speechSecs: 0.5, peakDb: -28))
        silence.simulateSpeechActivity(.resumed)
        await pumpUntil { coordinator.voiceFeedbackPhase == .hearing }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await clock.advance(by: .milliseconds(400))
        #expect(coordinator.voiceFeedbackPhase == .hearing, "the driver is still talking")
    }

    /// WHY: a cough must not claim the app is working on something.
    @Test("a blip (speech under the 0.25 s bar) clears hearing instead of processing")
    func blipNeverProcesses() async {
        let (_, coordinator, silence, clock) = make()
        silence.simulateSpeechActivity(.began(levelDb: -30, noiseFloorDb: -50))
        silence.simulateSpeechActivity(.paused(speechSecs: 0.1, peakDb: -28))
        silence.simulateSpeechActivity(.ended)
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle }, "a blip leaves nothing behind")
        await clock.advance(by: .milliseconds(500))
        #expect(coordinator.voiceFeedbackPhase == .idle)
    }

    /// WHY: "processing" must not lie forever when the recognizer never answers.
    @Test("processing clears at 2.5 s with nothing decided")
    func processingTimesOut() async {
        let (_, coordinator, silence, clock) = make()
        silence.simulateSpeechActivity(.began(levelDb: -30, noiseFloorDb: -50))
        silence.simulateSpeechActivity(.paused(speechSecs: 0.5, peakDb: -28))
        silence.simulateSpeechActivity(.ended) // hangover elapsed: processing at once
        await pumpUntil { self.isProcessing(coordinator) }
        await clock.advance(by: .milliseconds(2490))
        #expect(isProcessing(coordinator))
        await clock.advance(by: .milliseconds(10))
        await pumpUntil({ coordinator.voiceFeedbackPhase == .idle }, "a silent recognizer must not leave the spinner up")
    }

    /// WHY: speech too quiet for the level gate still reaches the recognizer;
    /// its words are proof enough that the driver was heard.
    @Test("a non-empty volatile lights hearing when the level gate missed the speech")
    func volatileBackupLightsHearing() async {
        let (_, coordinator, _, _) = make()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "hmm what was", isFinal: false))
        #expect(coordinator.voiceFeedbackPhase == .hearing)
    }

    // MARK: - Faster commit (#208.7 item 4)

    /// WHY: the founder waited ~1 s for every skip — it waited for the final
    /// although the 2.5 s undo window already guards a wrong one.
    @Test("skip fires from a stable volatile on the question screen (the undo window still guards it)")
    func skipFromStableVolatile() async {
        let (_, coordinator, _, _) = make()
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: false))
        #expect(coordinator.pendingSkipWindow == nil, "a first volatile may still grow into a sentence")
        await coordinator.handleCommandTranscript(CommandTranscript(text: "skip", isFinal: false))
        #expect(coordinator.pendingSkipWindow != nil, "a repeated volatile has stopped growing")
    }

    /// WHY: a pause on the answer sheet waited ~1 s for the final; a stable
    /// volatile already cleared the 0.85 floor and stopped growing.
    @Test("pause on the confirmation sheet may fire from a stable volatile")
    func pauseFromStableVolatile() {
        #expect(!VoiceCommandCoordinator.requiresFinalResult(.pause, on: .confirmation))
    }

    /// WHY: the no-answer sheet skips with no undo window behind it.
    @Test("skip on the no-answer sheet still waits for the final")
    func noAnswerSkipStaysFinal() {
        #expect(VoiceCommandCoordinator.requiresFinalResult(.skip, on: .noAnswer))
        #expect(!VoiceCommandCoordinator.requiresFinalResult(.skip, on: .question))
    }
}
