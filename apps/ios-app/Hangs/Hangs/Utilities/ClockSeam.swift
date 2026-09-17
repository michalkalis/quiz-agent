//
//  ClockSeam.swift
//  Hangs
//
//  #180 track A. Every timer, backoff and elapsed-time read on the quiz hot
//  path goes through ONE injected `AnyClock<Duration>`: `ContinuousClock` in
//  the app, `TestClock` / `ImmediateClock` (swift-clocks) in tests — so no
//  test waits on real time and the suite can run in parallel again.
//  `ContinuousClock` keeps counting while the device sleeps, which is what the
//  answer windows that keep running in the background need (#171 Track H).
//

import Clocks
import Foundation

extension AnyClock where Duration == Swift.Duration {
    /// The app's clock, type-erased so every owner stores the same seam type.
    static var continuous: AnyClock<Swift.Duration> { AnyClock(ContinuousClock()) }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for the elapsed-time policies that are
    /// specified in seconds (silence thresholds, glow windows, cooldowns).
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
