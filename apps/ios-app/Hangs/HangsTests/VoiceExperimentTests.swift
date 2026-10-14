//
//  VoiceExperimentTests.swift
//  HangsTests
//
//  #204.9: the app A/B tests three voice switches itself and a weekly job
//  turns the winner on for everyone. Why these matter: a config the app
//  cannot read must never break `/app-config` (forced update, orders, notice
//  ride on it); a coin that ignores the server's odds, or that overwrites the
//  founder's manual switches, makes every verdict the job reaches wrong; and an
//  AEC guard that forgets it tripped would keep pulling the sound out of the
//  car on the same phone, round after round.
//

import AVFoundation
import Foundation
@testable import Hangs
import Testing

/// The 50 % coin, reproducible: the sequence tests' SplitMix64.
private final class SeededRandom {
    var generator: SeededGenerator
    init(seed: UInt64) { generator = SeededGenerator(seed: seed) }
    func next() -> Double { Double.random(in: 0 ..< 1, using: &generator) }
}

private func arm(_ status: VoiceExperimentArm.Status = .running, p: Double, gen: Int = 1) -> VoiceExperimentArm {
    VoiceExperimentArm(status: status, pOn: p, generation: gen)
}

/// Every switch, both route groups, at the same odds.
private func config(p: Double, gen: Int = 1) -> VoiceExperimentConfig {
    let routes: [VoiceRouteGroup: VoiceExperimentArm] = [.btCar: arm(p: p, gen: gen), .other: arm(p: p, gen: gen)]
    return VoiceExperimentConfig(arms: Dictionary(uniqueKeysWithValues: VoiceExperimentFlag.allCases.map { ($0, routes) }))
}

private func freshDefaults() -> UserDefaults {
    UserDefaults(suiteName: "VoiceExperimentTests.\(UUID().uuidString)")!
}

private let manualKeys = [
    VoicePipelineFlags.Key.neuralVAD,
    VoicePipelineFlags.Key.echoCancelledInputOnExternalRoutes,
    VoicePipelineFlags.Key.frontCardioidMic,
]

@Suite("#204.9 voice experiment — config decoding")
struct VoiceExperimentDecodingTests {
    private func decode(_ json: String) throws -> RemoteAppConfig {
        try JSONDecoder().decode(RemoteAppConfig.self, from: Data(json.utf8))
    }

    @Test("the contract shape decodes into per switch, per route rows")
    func decodesContractShape() throws {
        let decoded = try decode("""
        {"orders_enabled": true, "voice_experiment": {
          "neural_vad": {"bt_car": {"status": "running", "p_on": 0.5, "generation": 2},
                         "other": {"status": "winner_on", "p_on": 1.0, "generation": 1}},
          "aec": {"other": {"status": "off", "p_on": 0.0, "generation": 1}}}}
        """)
        let experiment = try #require(decoded.voiceExperiment)
        #expect(experiment.arm(.neuralVAD, .btCar) == arm(p: 0.5, gen: 2))
        #expect(experiment.arm(.neuralVAD, .other)?.probabilityOn == 1)
        #expect(experiment.arm(.aec, .other)?.probabilityOn == 0)
        #expect(experiment.arm(.frontMic, .btCar) == nil, "a missing switch stays manual")
    }

    @Test("unknown switches, routes and unreadable rows are skipped, not fatal")
    func skipsUnknownAndBrokenRows() throws {
        let decoded = try decode("""
        {"voice_experiment": {
          "future_flag": {"bt_car": {"status": "running", "p_on": 0.5, "generation": 1}},
          "aec": {"bt_car": {"status": "paused", "p_on": 0.5, "generation": 1},
                  "moon": {"status": "running", "p_on": 0.5, "generation": 1}},
          "front_mic": {"bt_car": {"status": "running", "p_on": "half", "generation": 1},
                        "other": {"status": "running", "p_on": 0.3, "generation": 4}}}}
        """)
        let experiment = try #require(decoded.voiceExperiment)
        #expect(experiment.arms.keys.map(\.rawValue).sorted() == ["front_mic"])
        #expect(experiment.arm(.frontMic, .other) == arm(p: 0.3, gen: 4))
    }

    @Test("a voice_experiment that is not an object never costs the rest of the config", arguments: [
        #""voice_experiment": "on""#,
        #""voice_experiment": [1, 2]"#,
        #""voice_experiment": null"#,
    ])
    func malformedExperimentKeepsRestOfConfig(fragment: String) throws {
        let decoded = try decode(#"{"min_version_app_store": "9.9", "orders_enabled": false, \#(fragment)}"#)
        #expect(decoded.voiceExperiment == nil)
        #expect(decoded.minVersionAppStore == "9.9")
        #expect(decoded.ordersEnabled == false)
    }

    @Test("an old server without the field decodes as before")
    func missingFieldIsNil() throws {
        #expect(try decode(#"{"orders_enabled": true}"#).voiceExperiment == nil)
    }
}

@Suite("#204.9 voice experiment — assignment per round")
@MainActor
struct VoiceExperimentAssignmentTests {
    @Test("p_on 1 turns every switch on, p_on 0 off, with the server's generation")
    func certainOdds() {
        let on = VoiceExperimentStore(defaults: freshDefaults()).beginRound(config: config(p: 1, gen: 3), routeGroup: .btCar)
        let off = VoiceExperimentStore(defaults: freshDefaults()).beginRound(config: config(p: 0, gen: 3), routeGroup: .btCar)
        for flag in VoiceExperimentFlag.allCases {
            #expect(on[flag] == VoiceFlagAssignment(isOn: true, source: .auto, generation: 3))
            #expect(off[flag] == VoiceFlagAssignment(isOn: false, source: .auto, generation: 3))
        }
    }

    @Test("p_on 0.5 is an independent fair coin per switch and round")
    func halfOddsIsFairAndIndependent() {
        let random = SeededRandom(seed: 2049)
        let store = VoiceExperimentStore(defaults: freshDefaults(), random: random.next)
        var onCounts: [VoiceExperimentFlag: Int] = [:]
        var allSame = 0
        let rounds = 2000
        for _ in 0 ..< rounds {
            let assignment = store.beginRound(config: config(p: 0.5), routeGroup: .other)
            let values = VoiceExperimentFlag.allCases.map { assignment[$0]?.isOn == true }
            for (flag, isOn) in zip(VoiceExperimentFlag.allCases, values) where isOn {
                onCounts[flag, default: 0] += 1
            }
            if Set(values).count == 1 { allSame += 1 }
        }
        for flag in VoiceExperimentFlag.allCases {
            let share = Double(onCounts[flag] ?? 0) / Double(rounds)
            #expect(abs(share - 0.5) < 0.05, "\(flag) on in \(share) of rounds")
        }
        // Independent coins agree on all three in 1/4 of rounds; one shared
        // coin would make that every round and confound the three verdicts.
        #expect(abs(Double(allSame) / Double(rounds) - 0.25) < 0.05)
    }

    @Test("the coin is compared with the row of the round's route group")
    func usesRouteGroupRow() {
        let split = VoiceExperimentConfig(arms: [.aec: [.btCar: arm(p: 1, gen: 2), .other: arm(.off, p: 0, gen: 1)]])
        let store = VoiceExperimentStore(defaults: freshDefaults())
        #expect(store.beginRound(config: split, routeGroup: .btCar)[.aec]?.isOn == true)
        #expect(store.beginRound(config: split, routeGroup: .other)[.aec] == VoiceFlagAssignment(isOn: false, source: .auto, generation: 1))
    }

    @Test("no config, or no row for a switch, falls back to the manual switch")
    func missingConfigIsManual() {
        let defaults = freshDefaults()
        defaults.set(true, forKey: VoicePipelineFlags.Key.neuralVAD)
        let store = VoiceExperimentStore(defaults: defaults)

        let none = store.beginRound(config: nil, routeGroup: .btCar)
        #expect(none[.neuralVAD] == .manual(true))
        #expect(none[.aec] == .manual(false))

        let partial = store.beginRound(config: VoiceExperimentConfig(arms: [.aec: [.btCar: arm(p: 1)]]), routeGroup: .btCar)
        #expect(partial[.aec]?.source == .auto)
        #expect(partial[.neuralVAD] == .manual(true))
        #expect(store.isOn(.neuralVAD), "the capture reads the effective value")
    }

    @Test("master switch off: the manual switches apply exactly, whatever the server says")
    func masterOffIsManual() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: VoicePipelineFlags.Key.autoTesting)
        defaults.set(true, forKey: VoicePipelineFlags.Key.frontCardioidMic)
        let assignment = VoiceExperimentStore(defaults: defaults).beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(!assignment.autoTesting)
        #expect(assignment[.frontMic] == .manual(true))
        #expect(assignment[.neuralVAD] == .manual(false))
        #expect(assignment[.aec] == .manual(false))
    }

    @Test("master switch off: a manual switch flipped mid-round applies at the next read, as before 204.9")
    func masterOffStaysLive() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: VoicePipelineFlags.Key.autoTesting)
        let store = VoiceExperimentStore(defaults: defaults)
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(store.assignment == nil, "nothing frozen for the round")
        #expect(!store.isOn(.neuralVAD))
        defaults.set(true, forKey: VoicePipelineFlags.Key.neuralVAD)
        #expect(store.isOn(.neuralVAD))
    }

    @Test("a switch without a server row stays live too")
    func manualSourcedFlagIsLive() {
        let defaults = freshDefaults()
        let store = VoiceExperimentStore(defaults: defaults)
        store.beginRound(config: VoiceExperimentConfig(arms: [.aec: [.btCar: arm(p: 1)]]), routeGroup: .btCar)
        defaults.set(true, forKey: VoicePipelineFlags.Key.frontCardioidMic)
        #expect(store.isOn(.frontMic))
        #expect(store.isOn(.aec))
    }

    @Test("ending the round drops the experiment values")
    func endRoundRestoresManual() {
        let store = VoiceExperimentStore(defaults: freshDefaults())
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(store.isOn(.neuralVAD))
        store.endRound()
        #expect(!store.isOn(.neuralVAD))
        #expect(!store.isRoundActive)
    }

    @Test("aec_applicable: unknown until iOS reported the capability, then fixed at the round's start for both arms")
    func aecApplicableIsArmIndependent() {
        let store = VoiceExperimentStore(defaults: freshDefaults())
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(store.aecApplicable(outputPort: "BluetoothA2DPOutput") == nil)
        store.noteEchoCancelledInputCapability(true)
        #expect(store.aecApplicable(outputPort: "BluetoothA2DPOutput") == nil, "an ON round must not make only its own arm applicable")

        store.beginRound(config: config(p: 0), routeGroup: .btCar)
        #expect(store.aecApplicable(outputPort: "BluetoothA2DPOutput") == true, "the OFF arm counts once the device is known capable")
        #expect(store.aecApplicable(outputPort: "CarAudio") == true)
        #expect(store.aecApplicable(outputPort: "BluetoothHFP") == false, "AEC is never applied on hands-free")
        #expect(store.aecApplicable(outputPort: "Speaker") == false)

        store.noteEchoCancelledInputCapability(false)
        #expect(store.echoCancelledInputCapable == true, "a false read outside the right mode never undoes a known capability")
    }

    @Test("the master switch defaults on")
    func masterDefaultsOn() {
        #expect(VoicePipelineFlags.autoTesting(in: freshDefaults()))
    }

    @Test("assigning, the guard and ending a round never write the manual switches")
    func neverWritesManualKeys() {
        let defaults = freshDefaults()
        let store = VoiceExperimentStore(defaults: defaults)
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        _ = store.handleRouteChange(routeChange(.override, from: "BluetoothA2DPOutput", to: "Speaker"))
        store.beginRound(config: config(p: 0), routeGroup: .other)
        store.endRound()
        for key in manualKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) was written")
        }
    }
}

private func routeChange(_ reason: AVAudioSession.RouteChangeReason, from: String, to: String) -> AudioRouteChange {
    AudioRouteChange(reason: reason, outputPort: to, previousOutputPort: from, voiceProcessingMode: .offOutput)
}

@Suite("#204.9 voice experiment — AEC guard")
@MainActor
struct VoiceExperimentGuardTests {
    @Test("sound leaving the car for the speaker turns AEC off and reports it")
    func guardTrips() {
        let defaults = freshDefaults()
        let store = VoiceExperimentStore(defaults: defaults)
        store.beginRound(config: config(p: 1, gen: 3), routeGroup: .btCar)

        let event = store.handleRouteChange(routeChange(.categoryChange, from: "BluetoothA2DPOutput", to: "Speaker"))

        #expect(event == .voiceExperimentGuard(flag: .aec, fromRoute: "BluetoothA2DPOutput", toRoute: "Speaker", expGen: 3))
        #expect(!store.isOn(.aec), "off for the rest of the round")
        #expect(store.flag(.aec).generation == nil, "later answers this round stay out of the evaluation")
        #expect(store.isOn(.neuralVAD), "the other switches keep their coin")
        #expect(store.aecBlockedGeneration == 3)
        #expect(store.handleRouteChange(routeChange(.override, from: "CarAudio", to: "Receiver")) == nil, "reported once")
    }

    @Test("a tripped guard blocks AEC for the same generation, not for a restarted experiment")
    func blockedGenerationPersists() {
        let defaults = freshDefaults()
        let first = VoiceExperimentStore(defaults: defaults)
        first.beginRound(config: config(p: 1, gen: 3), routeGroup: .btCar)
        _ = first.handleRouteChange(routeChange(.override, from: "CarAudio", to: "Speaker"))

        // A new store = a relaunch: the block lives in UserDefaults.
        let sameGen = VoiceExperimentStore(defaults: defaults).beginRound(config: config(p: 1, gen: 3), routeGroup: .btCar)
        #expect(sameGen[.aec] == VoiceFlagAssignment(isOn: false, source: .auto, generation: nil))
        #expect(sameGen[.neuralVAD]?.isOn == true)

        let newGen = VoiceExperimentStore(defaults: defaults).beginRound(config: config(p: 1, gen: 4), routeGroup: .btCar)
        #expect(newGen[.aec] == VoiceFlagAssignment(isOn: true, source: .auto, generation: 4))
    }

    @Test("hands-free to speaker never trips: AEC is not applied on HFP")
    func hfpDoesNotTrip() {
        let store = VoiceExperimentStore(defaults: freshDefaults())
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(store.handleRouteChange(routeChange(.override, from: "BluetoothHFP", to: "Speaker")) == nil)
        #expect(store.isOn(.aec))
    }

    @Test("after the quiz ended a route change is not the guard")
    func noGuardOutsideRound() {
        let store = VoiceExperimentStore(defaults: freshDefaults())
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        store.endRound()
        #expect(store.handleRouteChange(routeChange(.override, from: "BluetoothA2DPOutput", to: "Speaker")) == nil)
        #expect(store.aecBlockedGeneration == nil)
    }

    @Test("the car going away is a disconnect, not the guard")
    func disconnectDoesNotTrip() {
        let store = VoiceExperimentStore(defaults: freshDefaults())
        store.beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(store.handleRouteChange(routeChange(.oldDeviceUnavailable, from: "BluetoothA2DPOutput", to: "Speaker")) == nil)
        #expect(store.isOn(.aec))
        #expect(store.aecBlockedGeneration == nil)
    }

    @Test("manual AEC, or AEC the coin left off, never trips the guard")
    func manualNeverTrips() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: VoicePipelineFlags.Key.autoTesting)
        defaults.set(true, forKey: VoicePipelineFlags.Key.echoCancelledInputOnExternalRoutes)
        let manual = VoiceExperimentStore(defaults: defaults)
        manual.beginRound(config: config(p: 1), routeGroup: .btCar)
        #expect(manual.handleRouteChange(routeChange(.override, from: "BluetoothA2DPOutput", to: "Speaker")) == nil)

        let coinOff = VoiceExperimentStore(defaults: freshDefaults())
        coinOff.beginRound(config: config(p: 0), routeGroup: .btCar)
        #expect(coinOff.handleRouteChange(routeChange(.override, from: "BluetoothA2DPOutput", to: "Speaker")) == nil)
    }
}

@Suite("#204.9 voice experiment — events")
struct VoiceExperimentEventTests {
    private func report(flags: [VoiceExperimentFlag: VoiceFlagAssignment], endDelayMs: Int? = 640) -> AnswerCapturedReport {
        AnswerCapturedReport(
            questionId: "q_001", isRetry: true, autoTest: true, flags: flags, routeGroup: .btCar,
            outputRoute: "BluetoothA2DPOutput", inputRoute: "MicrophoneBuiltIn", stopReason: .vad,
            detector: "neural", heardSpeech: true, speechMs: 900, endDelayMs: endDelayMs, durationMs: 2400,
            voiceProcessing: false, ecEnabled: true, aecApplicable: true, frontMicApplicable: true,
            micDataSource: "Front", micPolarPattern: "Cardioid", rejectedCount: 1
        )
    }

    @Test("answer_captured carries exactly the contract's keys and arm values")
    func answerCapturedKeys() {
        let event = AnalyticsEvent.answerCaptured(report(flags: [
            .neuralVAD: VoiceFlagAssignment(isOn: true, source: .auto, generation: 2),
            .aec: VoiceFlagAssignment(isOn: false, source: .auto, generation: 1),
            .frontMic: .manual(true),
        ]))
        let properties = event.properties
        #expect(event.name == "answer_captured")
        #expect(Set(properties.keys) == [
            "question_id", "is_retry", "auto_test", "src_neural_vad", "src_aec", "src_front_mic",
            "neural_vad", "aec", "front_mic", "exp_gen_neural_vad", "exp_gen_aec",
            "route_group", "output_route", "input_route", "stop_reason", "detector", "heard_speech",
            "speech_ms", "end_delay_ms", "duration_ms", "voice_processing", "ec_enabled", "aec_applicable",
            "front_mic_applicable", "mic_data_source", "mic_polar_pattern", "rejected_count",
        ], "a manual switch has no generation: the evaluator must not count it in an arm")
        #expect(properties["neural_vad"] == .bool(true))
        #expect(properties["src_neural_vad"] == .string("auto"))
        #expect(properties["exp_gen_neural_vad"] == .int(2))
        #expect(properties["src_front_mic"] == .string("manual"))
        #expect(properties["route_group"] == .string("bt_car"))
        #expect(properties["stop_reason"] == .string("vad"))
        #expect(properties["rejected_count"] == .int(1))
    }

    @Test("end delay: the recording's tail after the last word, unknown without speech")
    func endDelay() {
        #expect(AnswerCapturedReport.endDelayMs(durationMs: 2400, lastSpeechEndMs: 1760) == 640)
        #expect(AnswerCapturedReport.endDelayMs(durationMs: 2400, lastSpeechEndMs: nil) == nil)
        #expect(AnalyticsEvent.answerCaptured(report(flags: [:], endDelayMs: nil)).properties["end_delay_ms"] == nil)
        var unknown = report(flags: [:])
        unknown.aecApplicable = nil
        #expect(AnalyticsEvent.answerCaptured(unknown).properties["aec_applicable"] == nil, "unknown capability is left out, not sent as false")
    }

    @Test("voice_experiment_guard says which arm, why, between which routes and in which generation")
    func guardEvent() {
        let event = AnalyticsEvent.voiceExperimentGuard(flag: .aec, fromRoute: "CarAudio", toRoute: "Speaker", expGen: 3)
        #expect(event.name == "voice_experiment_guard")
        #expect(event.properties == [
            "flag": .string("aec"), "reason": .string("output_route_changed"),
            "from_route": .string("CarAudio"), "to_route": .string("Speaker"), "exp_gen": .int(3),
        ])
    }

    @Test("rejected_count counts every rejection on the question, repeats included")
    func rejectionCount() {
        var rejected = RejectedTranscripts()
        rejected.add("mokrá", questionKey: "q1")
        rejected.add("mokrá", questionKey: "q1")
        #expect(rejected.rejectionCount(for: "q1") == 2, "a second rejection of the same words is still a bad capture")
        rejected.remove("mokrá", questionKey: "q1")
        #expect(rejected.rejectionCount(for: "q1") == 2, "a take back never lowers it: the evaluator compares cumulative counts")
        #expect(rejected.rejectionCount(for: "q2") == 0)
        rejected.add("modrá", questionKey: "q2")
        #expect(rejected.rejectionCount(for: "q2") == 1, "a new question starts from zero")
    }
}
