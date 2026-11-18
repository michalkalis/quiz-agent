//
//  ReadAloudOutcome.swift
//  Hangs
//
//  #235 F3: what one "hear it" read managed.
//

import Foundation

/// What one "hear it" read managed: something played, a clip could not be had.
struct ReadAloudOutcome {
    var played = false
    var failed = false
}
