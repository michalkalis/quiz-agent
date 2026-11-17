//
//  ClockDriving.swift
//  HangsTests
//
//  #235.2 (flow × condition tests): a bad network can keep a flow busy for a
//  minute and more on the injected clock (three /usage timeouts, a start
//  retrying for its whole window). These tests ask "does the player ever get
//  out?", not "at which millisecond?", so they step the clock until the
//  outcome shows and fail if it never does within a stated bound.
//

import Clocks
@testable import Hangs
import Testing

/// Steps `clock` by `step` until `predicate` holds, letting the scheduler run
/// after every step. Returns the time it took, or records an issue when the
/// predicate still fails after `limit` (the "endless waiting" the tests rule out).
@MainActor
@discardableResult
func advanceUntil(
    _ clock: TestClock<Duration>,
    step: Duration = .seconds(1),
    limit: Duration,
    _ predicate: @MainActor () -> Bool,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> Duration {
    var elapsed: Duration = .zero
    while true {
        for _ in 0 ..< 50 {
            if predicate() { return elapsed }
            await Task.yield()
        }
        if predicate() { return elapsed }
        guard elapsed < limit else {
            Issue.record(comment ?? "still waiting after \(limit)", sourceLocation: sourceLocation)
            return elapsed
        }
        await clock.advance(by: step)
        elapsed += step
    }
}
