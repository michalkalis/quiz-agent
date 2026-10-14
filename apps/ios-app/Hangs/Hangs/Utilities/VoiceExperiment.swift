//
//  VoiceExperiment.swift
//  Hangs
//
//  #204.9 (founder 2026-10-14: "the app should run and test the settings
//  itself, I'm afraid I'll forget"): the three answer-capture switches of
//  #204.3 / .4 / .5 are A/B tested by the app. The server sends, per switch and
//  route group, whether the test runs and with what odds (`voice_experiment`
//  in `/app-config`, contract `docs/issues/issue-204-answer-recognition.md`
//  section 204.9). Once per quiz round each switch gets its own coin; every
//  answer then reports which arm it ran on (`answer_captured`) and a weekly
//  job decides the winner. These are the pure rules; `VoiceExperimentStore`
//  holds the round's result.
//

@preconcurrency import AVFoundation
import Foundation

/// A switch under test, by its server id.
nonisolated enum VoiceExperimentFlag: String, CaseIterable, Sendable {
    /// #204.3 `VoicePipelineFlags.neuralVADEnabled`.
    case neuralVAD = "neural_vad"
    /// #204.4 `VoicePipelineFlags.echoCancelledInputOnExternalRoutes`.
    case aec
    /// #204.5 `VoicePipelineFlags.frontCardioidMic`.
    case frontMic = "front_mic"
}

/// Where the sound goes, as the experiment splits it: the car (Bluetooth or
/// CarPlay) or anything else. Each group has its own odds and its own verdict.
nonisolated enum VoiceRouteGroup: String, Sendable, Equatable {
    case btCar = "bt_car"
    case other

    static let btCarOutputs: Set<AVAudioSession.Port> = [
        .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .carAudio,
    ]

    init(output: AVAudioSession.Port?) {
        self = output.map { Self.btCarOutputs.contains($0) } == true ? .btCar : .other
    }

    /// From the port names the route log carries ("BluetoothA2DPOutput", …).
    init(outputPortName: String) {
        self.init(output: AVAudioSession.Port(rawValue: outputPortName))
    }

    @MainActor
    static var current: VoiceRouteGroup {
        VoiceRouteGroup(output: AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType)
    }
}

/// One (switch, route group) row of the server's experiment table.
nonisolated struct VoiceExperimentArm: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case running
        case winnerOn = "winner_on"
        case off
    }

    let status: Status
    let pOn: Double
    let generation: Int

    /// The chance this switch is ON for a round: the coin's odds while the
    /// test runs, certain once a verdict is in.
    var probabilityOn: Double {
        switch status {
        case .running: min(max(pOn, 0), 1)
        case .winnerOn: 1
        case .off: 0
        }
    }

    enum CodingKeys: String, CodingKey {
        case status
        case pOn = "p_on"
        case generation
    }
}

/// `voice_experiment` from `/app-config`. Decoded leniently: an unknown
/// switch or route key, or a row that does not parse, is skipped, and that
/// switch simply falls back to its manual value.
nonisolated struct VoiceExperimentConfig: Codable, Sendable, Equatable {
    let arms: [VoiceExperimentFlag: [VoiceRouteGroup: VoiceExperimentArm]]

    init(arms: [VoiceExperimentFlag: [VoiceRouteGroup: VoiceExperimentArm]]) {
        self.arms = arms
    }

    func arm(_ flag: VoiceExperimentFlag, _ group: VoiceRouteGroup) -> VoiceExperimentArm? {
        arms[flag]?[group]
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var arms: [VoiceExperimentFlag: [VoiceRouteGroup: VoiceExperimentArm]] = [:]
        for flagKey in container.allKeys {
            guard let flag = VoiceExperimentFlag(rawValue: flagKey.stringValue),
                  let routes = try? container.nestedContainer(keyedBy: Key.self, forKey: flagKey)
            else { continue }
            for routeKey in routes.allKeys {
                guard let group = VoiceRouteGroup(rawValue: routeKey.stringValue),
                      let arm = try? routes.decode(VoiceExperimentArm.self, forKey: routeKey)
                else { continue }
                arms[flag, default: [:]][group] = arm
            }
        }
        self.arms = arms
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (flag, routes) in arms {
            var nested = container.nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: flag.rawValue))
            for (group, arm) in routes {
                try nested.encode(arm, forKey: Key(stringValue: group.rawValue))
            }
        }
    }
}

/// Where a switch's value for this round came from.
nonisolated enum VoiceFlagSource: String, Sendable {
    /// The server's experiment (or the app's AEC guard acting on it).
    case auto
    /// The manual switch in Settings › voice diagnostics.
    case manual
}

nonisolated struct VoiceFlagAssignment: Sendable, Equatable {
    var isOn: Bool
    var source: VoiceFlagSource
    /// The experiment generation the coin came from; nil when manual or when
    /// the AEC guard decided (such answers stay out of the evaluation).
    var generation: Int?

    static func manual(_ isOn: Bool) -> VoiceFlagAssignment {
        VoiceFlagAssignment(isOn: isOn, source: .manual, generation: nil)
    }
}

/// One quiz round's values for the three switches. Fixed for the round.
nonisolated struct VoiceExperimentAssignment: Sendable, Equatable {
    let autoTesting: Bool
    let routeGroup: VoiceRouteGroup
    var flags: [VoiceExperimentFlag: VoiceFlagAssignment]

    subscript(flag: VoiceExperimentFlag) -> VoiceFlagAssignment? {
        flags[flag]
    }

    /// Per switch: an experiment row for this route group → a coin with its
    /// odds; no row, no config or the master switch off → the manual value.
    /// AEC on the car route never comes up ON on a device whose guard tripped
    /// in the same experiment generation (`aecBlockedGeneration`).
    static func make(
        config: VoiceExperimentConfig?,
        routeGroup: VoiceRouteGroup,
        autoTesting: Bool,
        manual: (VoiceExperimentFlag) -> Bool,
        aecBlockedGeneration: Int?,
        random: () -> Double
    ) -> VoiceExperimentAssignment {
        var flags: [VoiceExperimentFlag: VoiceFlagAssignment] = [:]
        for flag in VoiceExperimentFlag.allCases {
            guard autoTesting, let arm = config?.arm(flag, routeGroup) else {
                flags[flag] = .manual(manual(flag))
                continue
            }
            if flag == .aec, routeGroup == .btCar, aecBlockedGeneration == arm.generation {
                flags[flag] = VoiceFlagAssignment(isOn: false, source: .auto, generation: nil)
                continue
            }
            flags[flag] = VoiceFlagAssignment(
                isOn: random() < arm.probabilityOn,
                source: .auto,
                generation: arm.generation
            )
        }
        return VoiceExperimentAssignment(autoTesting: autoTesting, routeGroup: routeGroup, flags: flags)
    }

    /// The AEC guard: the experiment turned AEC on and the sound left the car
    /// for the iPhone's own speaker or receiver while the car was still there.
    /// `.oldDeviceUnavailable` is the car going away, not AEC's doing. The
    /// manual switch never trips it.
    func aecGuardTrips(
        reason: AVAudioSession.RouteChangeReason,
        previousOutput: String,
        newOutput: String
    ) -> Bool {
        guard let aec = flags[.aec], aec.isOn, aec.source == .auto, aec.generation != nil,
              reason != .oldDeviceUnavailable
        else { return false }
        let phoneOutputs: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        return VoiceRouteGroup(outputPortName: previousOutput) == .btCar
            && phoneOutputs.contains(AVAudioSession.Port(rawValue: newOutput))
    }
}
