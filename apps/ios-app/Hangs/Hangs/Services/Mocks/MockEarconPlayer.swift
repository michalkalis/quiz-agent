//
//  MockEarconPlayer.swift
//  Hangs
//
//  Test double for `EarconPlaying` (77.10). Records the ordered list of earcons
//  played so a test can assert that a given event triggers EXACTLY its cue and
//  that no cue is emitted during TTS.
//

import Foundation

@MainActor
final class MockEarconPlayer: EarconPlaying {
    private(set) var played: [Earcon] = []

    func play(_ earcon: Earcon) {
        played.append(earcon)
    }

    func reset() {
        played.removeAll()
    }
}
