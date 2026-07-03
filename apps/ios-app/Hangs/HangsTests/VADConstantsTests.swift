//
//  VADConstantsTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.11 — the centralised
//  STOP-on-silence tuning constants. Verifies:
//    • every knob sits inside its documented range;
//    • the detector sensitivity was lowered for road noise (.medium → .low);
//    • the min-speech-duration guard genuinely REJECTS a sub-threshold blip and
//      passes a real utterance (via the pure `SilenceStopDecision`, which is what
//      `SilenceDetectionService` consumes — the service itself is @available(iOS
//      26) and is skipped on the 18.6 sim, so we exercise the pure logic that CAN
//      fail rather than fake a detector test);
//    • the ElevenLabs streaming URL actually consumes the centralised params.
//
//  These are STARTING points finalised on-device at 77.15 — the range checks
//  bound the tuning, they don't pin an exact value.
//

import Foundation
import Testing
@testable import Hangs

@Suite("VAD tuning constants + min-speech blip rejection (77.11)")
struct VADConstantsTests {

    // MARK: - Ranges

    @Test("silence hangover sits in the documented 1.2–1.8 s band")
    func hangoverInBand() {
        #expect(VADTuning.silenceHangoverSecs >= 1.2)
        #expect(VADTuning.silenceHangoverSecs <= 1.8)
    }

    @Test("min-speech-duration is a small positive guard (0 < x <= 1 s)")
    func minSpeechInRange() {
        #expect(VADTuning.minSpeechDurationSecs > 0)
        #expect(VADTuning.minSpeechDurationSecs <= 1.0)
    }

    @Test("detector sensitivity is lowered to .low for road noise")
    func sensitivityLowered() {
        #expect(VADTuning.detectorSensitivity == .low)
    }

    @Test("ElevenLabs VAD params are sane starting points")
    func elevenLabsParamsSane() {
        #expect(VADTuning.elevenLabsVadSilenceThresholdSecs >= 1.0)
        #expect(VADTuning.elevenLabsVadSilenceThresholdSecs <= 2.5)
        #expect(VADTuning.elevenLabsMinSpeechDurationMs > 0)
        #expect(VADTuning.elevenLabsMinSilenceDurationMs > 0)
    }

    // MARK: - Blip rejection (the pure logic SilenceDetectionService consumes)

    @Test("a sub-threshold blip is rejected, not auto-submitted")
    func blipIsRejected() {
        // Speech shorter than the min-speech guard, but silence past the hangover:
        // the utterance is a cough/blip and must NOT trigger an auto-submit.
        let blip = VADTuning.minSpeechDurationSecs / 2
        let outcome = SilenceStopDecision.evaluate(
            speechDuration: blip,
            silenceElapsed: VADTuning.silenceHangoverSecs + 0.1
        )
        #expect(outcome == .rejectBlip, "a \(blip)s blip must be rejected, got \(outcome)")
    }

    @Test("a real utterance past the hangover triggers STOP")
    func realUtteranceStops() {
        let outcome = SilenceStopDecision.evaluate(
            speechDuration: VADTuning.minSpeechDurationSecs + 0.5,
            silenceElapsed: VADTuning.silenceHangoverSecs + 0.1
        )
        #expect(outcome == .stop, "a real utterance must STOP, got \(outcome)")
    }

    @Test("silence shorter than the hangover keeps waiting")
    func shortSilenceWaits() {
        let outcome = SilenceStopDecision.evaluate(
            speechDuration: 1.0,
            silenceElapsed: VADTuning.silenceHangoverSecs - 0.1
        )
        #expect(outcome == .wait, "below the hangover we must keep waiting, got \(outcome)")
    }

    @Test("speech exactly at the min-speech boundary is accepted (not a blip)")
    func boundaryUtteranceAccepted() {
        let outcome = SilenceStopDecision.evaluate(
            speechDuration: VADTuning.minSpeechDurationSecs,
            silenceElapsed: VADTuning.silenceHangoverSecs
        )
        #expect(outcome == .stop, "exactly the min-speech duration must count as speech, got \(outcome)")
    }

    // MARK: - ElevenLabs consumes the centralised params

    @Test("the ElevenLabs streaming URL carries the centralised VAD params")
    func elevenLabsURLConsumesConstants() throws {
        let url = try ElevenLabsSTTService.buildWebSocketURL(token: "t", languageCode: "sk")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })

        #expect(dict["vad_silence_threshold_secs"] == String(VADTuning.elevenLabsVadSilenceThresholdSecs))
        #expect(dict["min_speech_duration_ms"] == String(VADTuning.elevenLabsMinSpeechDurationMs))
        #expect(dict["min_silence_duration_ms"] == String(VADTuning.elevenLabsMinSilenceDurationMs))
    }

    @Test("Config forwards the centralised ElevenLabs threshold")
    func configForwardsThreshold() {
        #expect(Config.elevenLabsVadSilenceThresholdSecs == VADTuning.elevenLabsVadSilenceThresholdSecs)
    }
}
