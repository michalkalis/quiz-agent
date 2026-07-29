//
//  VolumeChangeMonitor.swift
//  Hangs
//
//  #131 Track E — diagnostic telemetry for the founder-reported hardware volume
//  drift (media volume set to 0, then rises during quiz play with no app code
//  that writes AVAudioSession.outputVolume). Observe-only: this file never
//  activates a session or changes audio-session behavior — it exists purely to
//  catch the mechanism (route change? category swap? external actor?) in the
//  field via Sentry.
//

import AVFoundation
import Foundation
import Sentry

/// Pure rise-detection: the founder's symptom is volume RISING while he set it
/// to 0, so only rises matter — drops (ducking, user turning it down) are noise.
/// Kept free of `AVAudioSession` so it is unit-testable with injected floats.
enum VolumeRiseDetector {
    /// Founder's symptom is a rise "from 0", not single-step float jitter —
    /// 0.05 (one hardware volume-button click is ~1/16 ≈ 0.0625) filters
    /// coalesced-notification noise while still catching the reported jump.
    static let riseThreshold: Float = 0.05

    static func isRise(old: Float, new: Float) -> Bool {
        new - old >= riseThreshold
    }
}

/// Caps how many Sentry EVENTS (not breadcrumbs) one app session sends for
/// volume rises. A flaky mechanism could fire repeatedly during a single
/// drive; a handful of events is enough to attribute the cause without
/// burning Sentry quota (event is billed, breadcrumb is free).
struct VolumeEventRateLimiter {
    let maxEvents: Int
    private(set) var count = 0

    init(maxEvents: Int = 5) {
        self.maxEvents = maxEvents
    }

    /// Returns `true` (and consumes one slot) if this event is still under the
    /// cap; `false` once the session has already reported `maxEvents` times.
    mutating func allow() -> Bool {
        guard count < maxEvents else { return false }
        count += 1
        return true
    }
}

/// Observes `AVAudioSession.outputVolume` via KVO and reports every change as a
/// Sentry breadcrumb (for correlation), escalating rises ≥ `VolumeRiseDetector
/// .riseThreshold` to an actual Sentry event (rate-limited).
///
/// KVO on `outputVolume` only fires while the session is ACTIVE — this class
/// never calls `setActive`/`setCategory` itself; it just registers the
/// observer once at app start and waits for whatever the app's normal audio
/// flow already does (`AudioService.setupAudioSession`).
@MainActor
final class VolumeChangeMonitor {
    static let shared = VolumeChangeMonitor()

    private var observation: NSKeyValueObservation?
    private var rateLimiter = VolumeEventRateLimiter()
    private weak var audioService: AudioServiceProtocol?

    private init() {}

    /// Idempotent — safe to call more than once (e.g. `AppState` re-init in
    /// tests); only the first call installs the KVO observer.
    func start(audioService: AudioServiceProtocol) {
        self.audioService = audioService
        guard observation == nil else { return }

        observation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.old, .new]
        ) { [weak self] _, change in
            guard let oldValue = change.oldValue, let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.handleVolumeChange(old: oldValue, new: newValue)
            }
        }
    }

    private func handleVolumeChange(old: Float, new: Float) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")

        let data: [String: Any] = [
            "old": old,
            "new": new,
            "delta": new - old,
            "outputs": outputs,
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "options": session.categoryOptions.rawValue,
            "isRecording": audioService?.isRecording ?? false,
            "isPlaying": audioService?.isPlaying ?? false,
        ]

        let crumb = Breadcrumb(level: .info, category: "audio.volume_change")
        crumb.message = "System output volume changed"
        crumb.data = data
        SentryBreadcrumb.add(crumb)

        guard VolumeRiseDetector.isRise(old: old, new: new), rateLimiter.allow() else { return }
        guard SentrySDK.isEnabled else { return }

        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: "System volume rose unexpectedly during quiz")
        // Attach the same diagnostic snapshot as `extra` so the event is
        // self-contained even if the breadcrumb trail is truncated
        // (`maxBreadcrumbs` in HangsApp.init).
        event.extra = data
        SentrySDK.capture(event: event)
    }
}
