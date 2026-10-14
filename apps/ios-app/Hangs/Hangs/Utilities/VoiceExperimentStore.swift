//
//  VoiceExperimentStore.swift
//  Hangs
//
//  #204.9: the round's assignment of the three tested switches, kept in memory
//  next to (never inside) the manual UserDefaults switches. Every capture
//  reads `isOn(_:)`: the round's experiment value while one is assigned, else
//  the manual switch, read live as before 204.9 (master switch off, no server
//  row, or outside a quiz). Also runs the AEC guard and remembers, per
//  experiment generation, that it tripped on this device.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VoiceExperimentStore {
    static let shared = VoiceExperimentStore()

    /// The round's experiment values; nil outside a round and when the
    /// master switch was off at its start.
    private(set) var assignment: VoiceExperimentAssignment?
    /// A quiz round is running (between `beginRound` and `endRound`).
    private(set) var isRoundActive = false
    private var roundRouteGroup: VoiceRouteGroup?
    /// Whether this device was known to support echo-cancelled input when
    /// the round started; nil = not known yet. Snapshotted before the coin's
    /// effect, so the AEC arms are filtered alike (see `aecApplicable`).
    private(set) var roundEchoCancelledInputCapable: Bool?

    private let defaults: UserDefaults
    private let random: () -> Double

    init(defaults: UserDefaults = .standard, random: @escaping () -> Double = { Double.random(in: 0 ..< 1) }) {
        self.defaults = defaults
        self.random = random
    }

    /// Assign the round's values. Called once per quiz round, before the
    /// round's first mic engine; the result holds until `endRound`.
    @discardableResult
    func beginRound(config: VoiceExperimentConfig?, routeGroup: VoiceRouteGroup) -> VoiceExperimentAssignment {
        let assignment = VoiceExperimentAssignment.make(
            config: config,
            routeGroup: routeGroup,
            autoTesting: VoicePipelineFlags.autoTesting(in: defaults),
            manual: { [defaults] in VoicePipelineFlags.manualValue($0, in: defaults) },
            aecBlockedGeneration: aecBlockedGeneration,
            random: random
        )
        // Master switch off: nothing is held, the manual switches stay live.
        self.assignment = assignment.autoTesting ? assignment : nil
        isRoundActive = true
        roundRouteGroup = routeGroup
        roundEchoCancelledInputCapable = echoCancelledInputCapable
        SentryLog.info("voice experiment assigned", category: .audio, attributes: sentryAttributes)
        return assignment
    }

    /// The quiz ended (or the master switch went off): drop the round's
    /// values, the manual switches apply at once.
    func endRound() {
        assignment = nil
        isRoundActive = false
        roundRouteGroup = nil
        roundEchoCancelledInputCapable = nil
    }

    /// An experiment value while the round holds one, else the live manual
    /// switch.
    func flag(_ flag: VoiceExperimentFlag) -> VoiceFlagAssignment {
        if let assigned = assignment?[flag], assigned.source == .auto { return assigned }
        return .manual(VoicePipelineFlags.manualValue(flag, in: defaults))
    }

    /// The value the capture runs with.
    func isOn(_ flag: VoiceExperimentFlag) -> Bool {
        self.flag(flag).isOn
    }

    var autoTesting: Bool {
        assignment?.autoTesting ?? VoicePipelineFlags.autoTesting(in: defaults)
    }

    var routeGroup: VoiceRouteGroup {
        roundRouteGroup ?? .current
    }

    /// Device capability for echo-cancelled input, as iOS reported it the
    /// last time the session ran in the mode the property is valid in
    /// (`.playAndRecord` + `.default`). Sticky once true: in other modes iOS
    /// reports false, which says nothing about the device.
    var echoCancelledInputCapable: Bool? {
        defaults.object(forKey: VoicePipelineFlags.Key.echoCancelledInputCapable) as? Bool
    }

    func noteEchoCancelledInputCapability(_ available: Bool) {
        guard echoCancelledInputCapable != true else { return }
        defaults.set(available, forKey: VoicePipelineFlags.Key.echoCancelledInputCapable)
    }

    /// `aec_applicable` for a capture on `outputPort`: a car output AEC is
    /// applied on, on a device known capable at the round's start. nil when
    /// the capability was not known yet.
    func aecApplicable(outputPort: String) -> Bool? {
        guard let capable = roundEchoCancelledInputCapable else { return nil }
        let port = AVAudioSession.Port(rawValue: outputPort)
        return capable && VoiceRouteGroup(output: port) == .btCar
            && MicCapturePolicy.echoCancelledInputOutputs.contains(port)
    }

    /// The `aec` × `bt_car` generation the guard tripped in on this device.
    var aecBlockedGeneration: Int? {
        defaults.object(forKey: VoicePipelineFlags.Key.aecBlockedGeneration) as? Int
    }

    /// The AEC guard on a route change: AEC goes off for the rest of the
    /// round (applied at the next mic engine start, the no-engine choke point
    /// the mic-capture reconcile runs at), the generation is remembered so no
    /// later round assigns it again, and the event to report is returned.
    func handleRouteChange(_ change: AudioRouteChange) -> AnalyticsEvent? {
        guard isRoundActive, var assignment,
              let generation = assignment[.aec]?.generation,
              assignment.aecGuardTrips(
                  reason: change.reason,
                  previousOutput: change.previousOutputPort,
                  newOutput: change.outputPort
              )
        else { return nil }
        assignment.flags[.aec] = VoiceFlagAssignment(isOn: false, source: .auto, generation: nil)
        self.assignment = assignment
        defaults.set(generation, forKey: VoicePipelineFlags.Key.aecBlockedGeneration)
        SentryLog.warn("voice experiment guard", category: .audio, attributes: [
            "flag": VoiceExperimentFlag.aec.rawValue,
            "fromRoute": change.previousOutputPort,
            "toRoute": change.outputPort,
            "expGen": generation,
        ])
        return .voiceExperimentGuard(
            flag: .aec,
            fromRoute: change.previousOutputPort,
            toRoute: change.outputPort,
            expGen: generation
        )
    }

    /// The effective values and their source, for "answer recording stopped"
    /// and the assignment log.
    var sentryAttributes: [String: Any] {
        var attributes: [String: Any] = [
            "autoTest": autoTesting,
            "expRouteGroup": routeGroup.rawValue,
        ]
        for flag in VoiceExperimentFlag.allCases {
            let value = self.flag(flag)
            attributes["exp_\(flag.rawValue)"] = value.isOn
            attributes["exp_\(flag.rawValue)_src"] = value.source.rawValue
            if let generation = value.generation { attributes["exp_\(flag.rawValue)_gen"] = generation }
        }
        return attributes
    }
}
