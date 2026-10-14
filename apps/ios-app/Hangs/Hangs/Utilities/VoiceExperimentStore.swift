//
//  VoiceExperimentStore.swift
//  Hangs
//
//  #204.9: the round's assignment of the three tested switches, kept in memory
//  next to (never inside) the manual UserDefaults switches. Every capture
//  reads `isOn(_:)`: the round's value while one is assigned, else the manual
//  switch. Also runs the AEC guard and remembers, per experiment generation,
//  that it tripped on this device.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VoiceExperimentStore {
    static let shared = VoiceExperimentStore()

    private(set) var assignment: VoiceExperimentAssignment?

    private let defaults: UserDefaults
    private let random: () -> Double

    init(defaults: UserDefaults = .standard, random: @escaping () -> Double = { Double.random(in: 0 ..< 1) }) {
        self.defaults = defaults
        self.random = random
    }

    /// Assign the round's values. Called once per quiz round, before the
    /// round's first mic engine; the result holds until the next round.
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
        self.assignment = assignment
        SentryLog.info("voice experiment assigned", category: .audio, attributes: sentryAttributes)
        return assignment
    }

    /// Drop the round's values: the manual switches apply at once (the master
    /// switch turned off).
    func endRound() {
        assignment = nil
    }

    func flag(_ flag: VoiceExperimentFlag) -> VoiceFlagAssignment {
        assignment?[flag] ?? .manual(VoicePipelineFlags.manualValue(flag, in: defaults))
    }

    /// The value the capture runs with.
    func isOn(_ flag: VoiceExperimentFlag) -> Bool {
        self.flag(flag).isOn
    }

    var autoTesting: Bool {
        assignment?.autoTesting ?? VoicePipelineFlags.autoTesting(in: defaults)
    }

    var routeGroup: VoiceRouteGroup {
        assignment?.routeGroup ?? .current
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
        guard var assignment,
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
