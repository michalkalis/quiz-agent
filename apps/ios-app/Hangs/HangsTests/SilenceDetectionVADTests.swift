//
//  SilenceDetectionVADTests.swift
//  HangsTests
//
//  #185 track A (car test 2026-09-23): the speech state machine as fed by the
//  energy detector, the clock-driven silence check, the per-recording
//  detection session and the no-speech-window verdict. Time is a `TestClock`
//  advanced 20 ms per tap buffer, so audio time and clock time move together.
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private final class EventBox {
    var events: [SilenceEvent] = []
    var stops: Int { events.filter { if case .silenceAfterSpeech = $0 { true } else { false } }.count }
    var starts: Int { events.filter { $0 == .speechStarted }.count }
}

@MainActor
private func record(_ service: SilenceDetectionService) -> EventBox {
    let box = EventBox()
    let stream = service.makeSilenceEventStream()
    Task { for await event in stream { box.events.append(event) } }
    return box
}

/// `seconds` of 20 ms buffers at `db`, the clock following audio time.
@MainActor
private func feed(_ service: SilenceDetectionService, _ clock: TestClock<Duration>, db: Float, seconds: Double) async {
    for _ in 0 ..< Int((seconds / 0.02).rounded()) {
        service.handleInputLevel(InputLevelSample(db: db, duration: 0.02))
        await clock.advance(by: .milliseconds(20))
    }
}

private let noiseDb: Float = -50
private let voiceDb: Float = -35

@Suite("#185 on-device speech detection — state machine, session, verdict")
@MainActor
struct SilenceDetectionVADTests {
    private func makeService() -> (SilenceDetectionService, TestClock<Duration>) {
        let clock = TestClock()
        return (SilenceDetectionService(clock: AnyClock(clock)), clock)
    }

    /// WHY: in the car the stop was only re-checked when a detector event came
    /// in. The hangover must end the answer on the clock even if the detector
    /// goes quiet (or the engine stalls) right after the last word.
    @Test("silence after speech stops at the hangover deadline with no further detector input")
    func clockDrivenSilenceStop() async {
        let (service, clock) = makeService()
        let box = record(service)
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        await feed(service, clock, db: noiseDb, seconds: 0.3)
        await feed(service, clock, db: voiceDb, seconds: 0.5)
        await pumpUntil({ box.starts == 1 }, "the answer never started")
        service.handleInputLevel(InputLevelSample(db: noiseDb, duration: 0.02)) // last buffer, then nothing

        await clock.advance(by: .milliseconds(799))
        #expect(box.stops == 0, "stopped before the hangover")
        await clock.advance(by: .milliseconds(1))
        await pumpUntil({ box.stops == 1 }, "the clock-driven check never fired")
        #expect(box.events.last == .silenceAfterSpeech(duration: VADTuning.silenceHangoverSecs))
    }

    /// WHY: "speech is detected if either detector says so" — a detector that
    /// still hears the driver must hold the recording open.
    @Test("either detector holds speech open; it ends only when both are quiet")
    func eitherDetectorCounts() async {
        let (service, clock) = makeService()
        let box = record(service)
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        await feed(service, clock, db: noiseDb, seconds: 0.3)

        service.handleSpeechDetectorResult(speechDetected: true) // energy quiet, detector hears speech
        await pumpUntil({ box.starts == 1 }, "a SpeechDetector speech result must start speech")
        await feed(service, clock, db: noiseDb, seconds: 1.0)
        #expect(box.stops == 0, "the energy detector's silence must not end speech the SpeechDetector hears")

        service.handleSpeechDetectorResult(speechDetected: false)
        await clock.advance(by: .milliseconds(800))
        await pumpUntil({ box.stops == 1 }, "both quiet → the hangover must stop it")
    }

    /// WHY (H3): the listener runs through the command window before the
    /// answer. A state left in "speech" there (a passenger talking) would
    /// swallow the answer's speech start — the countdown would never retire and
    /// the 5 s window would cut the answer.
    @Test("each recording starts from a clean slate — speech left from the command window cannot swallow the answer")
    func beginResetsLeftoverState() async {
        let (service, clock) = makeService()
        let box = record(service)
        await feed(service, clock, db: noiseDb, seconds: 0.3)
        await feed(service, clock, db: voiceDb, seconds: 0.2) // someone talks during the window
        await pumpUntil({ box.starts == 1 })

        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        #expect(service.noSpeechWindowVerdict == .noAudio, "no buffer measured in this recording yet")
        await feed(service, clock, db: noiseDb, seconds: 0.3)
        #expect(service.noSpeechWindowVerdict == .quiet, "the floor is re-measured for the recording")
        await feed(service, clock, db: voiceDb, seconds: 0.2)

        await pumpUntil({ box.starts == 2 }, "the answer's own speech start was swallowed")
    }

    /// WHY: "c" / "dva" is the whole MCQ answer; at the open-answer bar it was
    /// dropped as a blip and the recording ran on to the cap.
    @Test("a 120 ms answer stops the recording under the MCQ bar and is a blip under the open-answer bar")
    func mcqBlipBar() async {
        for (bar, expectedStops) in [(VADTuning.mcqMinSpeechDurationSecs, 1), (VADTuning.minSpeechDurationSecs, 0)] {
            let (service, clock) = makeService()
            let box = record(service)
            service.beginAnswerDetection(minSpeechDuration: bar)
            await feed(service, clock, db: noiseDb, seconds: 0.3)
            await feed(service, clock, db: voiceDb, seconds: 0.16) // speech from the 3rd buffer: 120 ms
            await feed(service, clock, db: noiseDb, seconds: 1.0)

            await pumpUntil({ box.starts == 1 })
            if expectedStops == 1 { await pumpUntil({ box.stops == 1 }, "MCQ syllable dropped as a blip") }
            #expect(box.stops == expectedStops, "bar \(bar) s")
        }
    }

    /// WHY (founder 2026-09-24): the 5 s window may cut a recording only when
    /// the detector demonstrably works and heard nothing — every other state
    /// must leave the answer to the cap.
    @Test("the no-speech window is allowed only for a live, calibrated detector that heard nothing")
    func noSpeechWindowVerdicts() async {
        let (service, clock) = makeService()
        #expect(service.noSpeechWindowVerdict == .noAudio, "no recording → nothing to vouch for")

        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        #expect(service.noSpeechWindowVerdict == .noAudio, "no audio has reached the detector")
        await feed(service, clock, db: noiseDb, seconds: 0.1)
        #expect(service.noSpeechWindowVerdict == .calibrating)
        await feed(service, clock, db: noiseDb, seconds: 0.2)
        #expect(service.noSpeechWindowVerdict == .quiet)
        #expect(service.noSpeechWindowVerdict.mayEndRecording)

        await clock.advance(by: .milliseconds(600))
        #expect(service.noSpeechWindowVerdict == .noAudio, "a stalled engine is not silence")
        await feed(service, clock, db: noiseDb, seconds: 0.02)
        #expect(service.noSpeechWindowVerdict == .quiet)

        await feed(service, clock, db: noiseDb + 5, seconds: 0.3) // a voice too quiet to clear the onset
        #expect(service.noSpeechWindowVerdict == .possibleSpeech)
        #expect(!service.noSpeechWindowVerdict.mayEndRecording)

        await feed(service, clock, db: voiceDb, seconds: 0.1)
        #expect(service.noSpeechWindowVerdict == .speechHeard)
    }

    /// WHY: a dead input delivers zeros — "quiet" there would be a lie.
    @Test("digital silence cannot vouch for anything")
    func digitalSilenceIsNoAudio() async {
        let (service, clock) = makeService()
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        await feed(service, clock, db: -160, seconds: 0.4)
        #expect(service.noSpeechWindowVerdict == .noAudio)
    }

    /// WHY: the next car test must prove which detector heard the driver and
    /// whether audio reached it at all — the report is that evidence.
    @Test("the recording report says who heard speech, how loud, and how many SpeechDetector results came")
    func recordingReport() async throws {
        let (service, clock) = makeService()
        service.speechDetectorPaired = true
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        await feed(service, clock, db: noiseDb, seconds: 0.3)
        await feed(service, clock, db: voiceDb, seconds: 0.5)
        service.handleSpeechDetectorResult(speechDetected: false)
        service.handleSpeechDetectorResult(speechDetected: false)

        let report = service.endAnswerDetection()
        #expect(report.speechHeardBy == "energy")
        #expect(report.speechDetectorResults == 2)
        #expect(report.levelBuffers == 40)
        #expect(abs(try #require(report.noiseFloorDb) - noiseDb) < 0.5)
        #expect(report.peakDb == voiceDb)
        #expect(report.speechMs == 460, "23 of the 25 voice buffers are past the 60 ms onset hold")
        #expect(report.minSpeechMs == 250)
        #expect(report.sentryAttributes["speechHeardBy"] as? String == "energy")

        #expect(service.noSpeechWindowVerdict == .noAudio, "the session is closed")
        #expect(service.endAnswerDetection() == .empty)
    }

    @Test("an unpaired SpeechDetector reports 'unpaired', not a misleading 0")
    func unpairedDetectorReport() {
        let (service, _) = makeService()
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)
        let report = service.endAnswerDetection()
        #expect(report.speechDetectorResults == nil)
        #expect(report.sentryAttributes["speechDetectorResults"] as? String == "unpaired")
    }

    /// WHY: track F draws the "the mic hears you" ring from this signal — one
    /// value per buffer, relative to the noise floor once it is known.
    @Test("the input level stream carries every buffer, relative to the noise floor")
    func inputLevelStream() async throws {
        let (service, clock) = makeService()
        let stream = service.makeInputLevelStream()
        let collected = Task { () -> [InputLevel] in
            var levels: [InputLevel] = []
            for await level in stream {
                levels.append(level)
                if levels.count == 16 { break }
            }
            return levels
        }
        await feed(service, clock, db: noiseDb, seconds: 0.3)
        await feed(service, clock, db: voiceDb, seconds: 0.02)

        let levels = await collected.value
        #expect(levels.first?.noiseFloorDb == nil, "calibrating")
        #expect(levels.first?.normalized == 0)
        let last = try #require(levels.last)
        #expect(last.db == voiceDb)
        #expect(last.normalized > 0.4, "15 dB over the floor is half the ring")
    }

    /// End to end on synthetic cabin PCM through the tap's meter: loud engine,
    /// road hiss, a normal-voice answer — the recording must start on the voice
    /// and stop after it, and the report must say the energy detector heard it.
    @Test("cabin noise + a spoken answer: speech start, auto-stop after it, energy in the report")
    func cabinAnswerEndToEnd() async {
        let (service, clock) = makeService()
        let box = record(service)
        var cabin = SyntheticCabin()
        var meter = InputLevelMeter(sampleRate: SyntheticCabin.sampleRate)
        service.beginAnswerDetection(minSpeechDuration: VADTuning.minSpeechDurationSecs)

        let audio = cabin.segment(seconds: 1) + cabin.segment(seconds: 1.5, speechDb: -38)
            + cabin.segment(seconds: 1.2)
        for buffer in SyntheticCabin.buffers(audio) {
            guard let level = meter.measure(buffer) else { continue }
            service.handleInputLevel(level)
            await clock.advance(by: SyntheticCabin.bufferDuration)
        }

        await pumpUntil({ box.stops == 1 }, "the answer never auto-stopped")
        #expect(box.starts == 1, "one answer, one speech start — syllable dips must not split it")
        let report = service.endAnswerDetection()
        #expect(report.speechHeardBy == "energy")
        #expect(report.speechMs > 700, "most of the 1.5 s answer counted as speech (got \(report.speechMs) ms)")
    }
}
