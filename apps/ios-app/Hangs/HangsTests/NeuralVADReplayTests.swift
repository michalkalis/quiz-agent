//
//  NeuralVADReplayTests.swift
//  HangsTests
//
//  #204 track 204.3: the bundled Silero model against the energy detector on
//  the car failure (Sentry 2026-10-10: 7 of 40 answers ran to the 8 s cap,
//  four with 9.5–14.7 s of road noise counted as "speech"). Each case replays
//  a spoken answer over road noise through the real state machine (see
//  RoadNoiseReplay.swift) once per detector, so the asserted difference is
//  the detector and nothing else.
//

import Foundation
@testable import Hangs
import Testing

@Suite("#204 neural VAD replay — road noise vs. a spoken answer", .serialized)
@MainActor
struct NeuralVADReplayTests {
    /// The hangover is 0.8 s; Silero needs a window or two (32 ms each) to
    /// release, the replay sees the stop one buffer late. 1.2 s after the
    /// last word is "the recording ended promptly".
    private static let promptStopSecs = 1.2

    /// WHY: the bug itself. After the answer the road gets louder (a truck, a
    /// rough stretch) and the level detector — calibrated on the quieter road
    /// before the answer — keeps calling it speech, so the driver waits for
    /// the 8 s cap. The model knows noise is not a voice and ends the
    /// recording within the hangover.
    @Test("noise swelling after the answer: neural ends within ~1 s, energy runs to the cap")
    func swellingNoiseAfterAnswer() async throws {
        let vad = try await SileroVAD.loadBundled()
        let cabin = try CabinAnswer(speech: ReplayFixture.speech("vad_answer_sk"), swellDb: 14)
        let audio = cabin.mix()

        let neural = await DetectorReplay.run(audio, neural: vad)
        let energy = await DetectorReplay.run(audio, neural: nil)

        #expect(neural.report.detector == .neural)
        #expect(neural.report.sentryAttributes["detector"] as? String == "neural", "the A/B field on 'answer recording stopped'")
        #expect(energy.report.detector == .energy)
        let neuralStop = try #require(neural.stopSecs, "the neural detector never ended the answer: \(neural.report)")
        #expect(neuralStop > cabin.speechEndSecs, "stopped at \(neuralStop) s, before the answer ended at \(cabin.speechEndSecs) s")
        #expect(
            neuralStop <= cabin.speechEndSecs + Self.promptStopSecs,
            "stopped \(neuralStop - cabin.speechEndSecs) s after the last word"
        )
        #expect(energy.stopSecs == nil, "energy stopped at \(energy.stopSecs ?? -1) s — the scenario no longer reproduces the car bug")
    }

    /// WHY: the switch must not cost the normal case — on a steady road the
    /// model hears the answer start inside the spoken words and ends it as
    /// promptly as the energy detector does today.
    @Test("steady road: neural hears the answer and ends it within ~1 s")
    func steadyRoadAnswer() async throws {
        let vad = try await SileroVAD.loadBundled()
        let cabin = try CabinAnswer(speech: ReplayFixture.speech("vad_answer_en"))
        let neural = await DetectorReplay.run(cabin.mix(), neural: vad)

        let onset = try #require(neural.firstSpeechSecs, "no speech heard: \(neural.report)")
        #expect(onset >= cabin.leadInSecs && onset < cabin.leadInSecs + 0.5, "onset at \(onset) s")
        let stop = try #require(neural.stopSecs, "the answer never ended: \(neural.report)")
        #expect(stop <= cabin.speechEndSecs + Self.promptStopSecs, "stopped \(stop - cabin.speechEndSecs) s after the last word")
    }

    /// WHY: the 5 s "start speaking" window may only end a recording when the
    /// detector is sure nobody spoke (#185). A silent driver on a road that
    /// gets louder reads as "maybe speech" to the level detector, so today the
    /// recording runs on to the cap; the model can vouch it heard no voice.
    @Test("no answer, road getting louder: neural lets the 5 s window close, energy cannot")
    func silentDriverSwellingRoad() async throws {
        let vad = try await SileroVAD.loadBundled()
        let cabin = CabinAnswer(speech: [], leadInSecs: 1.0, totalSecs: 5.2, swellDb: 14)
        let audio = cabin.mix()

        let neural = await DetectorReplay.run(audio, neural: vad)
        let energy = await DetectorReplay.run(audio, neural: nil)

        #expect(neural.report.neuralHeardSpeech == false, "road noise scored as speech (peak \(neural.report.neuralPeakProbability ?? -1))")
        #expect(neural.noSpeechVerdictAt5s == .quiet, "neural verdict \(String(describing: neural.noSpeechVerdictAt5s))")
        #expect(energy.noSpeechVerdictAt5s?.mayEndRecording == false, "energy verdict \(String(describing: energy.noSpeechVerdictAt5s))")
    }

    /// WHY: a broken model must never leave the answer without a detector —
    /// a model that stops scoring hands the recording back to the energy
    /// detector (which still ends a steady-road answer), and Sentry says so.
    @Test("a model that never scores falls back to the energy detector")
    func silentModelFallsBack() async throws {
        let vad = try await SileroVAD.loadBundled()
        let cabin = try CabinAnswer(speech: ReplayFixture.speech("vad_answer_en"))
        let outcome = await DetectorReplay.run(cabin.mix(), neural: vad, modelScores: false)

        #expect(outcome.report.detector == .energyFallback)
        let stop = try #require(outcome.stopSecs, "the fallback never ended the answer: \(outcome.report)")
        #expect(stop > cabin.speechEndSecs && stop <= cabin.speechEndSecs + Self.promptStopSecs)
    }
}
