//
//  VolumeChangeMonitorTests.swift
//  HangsTests
//
//  #131 Track E — volume-change telemetry. Tests the pure rise-detector and
//  event rate-limiter with injected floats; the KVO/Sentry wiring itself needs
//  a real AVAudioSession + Sentry SDK and isn't exercised here.
//

import Foundation
@testable import Hangs
import Testing

@Suite("VolumeRiseDetector")
struct VolumeRiseDetectorTests {
    @Test("a rise at or above the threshold is flagged — this is the founder's exact symptom")
    func riseAtThresholdIsFlagged() {
        #expect(VolumeRiseDetector.isRise(old: 0.0, new: 0.05))
        #expect(VolumeRiseDetector.isRise(old: 0.2, new: 0.4))
    }

    @Test("a rise below the threshold is ignored — filters coalesced-notification jitter, not the reported jump")
    func subThresholdRiseIsIgnored() {
        #expect(!VolumeRiseDetector.isRise(old: 0.0, new: 0.04))
        #expect(!VolumeRiseDetector.isRise(old: 0.5, new: 0.52))
    }

    @Test("a drop is never flagged — the founder's symptom is volume rising, not ducking/manual turn-down")
    func dropIsNeverFlagged() {
        #expect(!VolumeRiseDetector.isRise(old: 0.8, new: 0.0))
        #expect(!VolumeRiseDetector.isRise(old: 0.5, new: 0.5))
    }
}

@Suite("VolumeEventRateLimiter")
struct VolumeEventRateLimiterTests {
    @Test("allows events up to the cap, then blocks — a flaky mechanism must not spam paid Sentry events")
    func blocksAfterCap() {
        var limiter = VolumeEventRateLimiter(maxEvents: 2)

        let first = limiter.allow()
        let second = limiter.allow()
        let third = limiter.allow()
        let fourth = limiter.allow()

        #expect(first)
        #expect(second)
        #expect(!third)
        #expect(!fourth, "stays blocked, doesn't reset on repeated calls")
    }

    @Test("default cap is a small handful, per the founder's rate-limit requirement")
    func defaultCapIsSmall() {
        var limiter = VolumeEventRateLimiter()

        var allowedCount = 0
        for _ in 0..<10 where limiter.allow() {
            allowedCount += 1
        }

        #expect(allowedCount == limiter.maxEvents)
        #expect(allowedCount <= 5)
    }
}
