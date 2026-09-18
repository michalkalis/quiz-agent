//
//  MainSerialExecutorBootstrap.swift
//  HangsTests
//
//  #180 track A. Swift Testing runs suites concurrently in one process, and
//  many suites here enter `withMainSerialExecutor` — a PROCESS-GLOBAL hook.
//  With two suites in flight, one leaving its scope restored `false` under the
//  other, whose main-actor jobs then landed on the real main queue mid-await
//  and starved (the 3-of-4 flaky full-suite runs that forced CI serial).
//
//  So the hook is set ONCE, at bundle load, for the whole process: every
//  main-actor job runs on the main serial executor for the entire run, the
//  per-test scopes nest harmlessly (they restore `true`), and — now that no
//  test waits on real time — `TestClock.advance` interleaves deterministically.
//  Wired through `INFOPLIST_KEY_NSPrincipalClass`; XCTest instantiates the
//  principal class before any test in the bundle runs.
//

import ConcurrencyExtras
import Foundation

@objc(MainSerialExecutorBootstrap)
final class MainSerialExecutorBootstrap: NSObject {
    override init() {
        uncheckedUseMainSerialExecutor = true
        super.init()
    }
}
