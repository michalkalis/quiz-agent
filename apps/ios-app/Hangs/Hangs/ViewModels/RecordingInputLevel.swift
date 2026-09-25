//
//  RecordingInputLevel.swift
//  Hangs
//
//  #185 track F (founder pick F2 "Lišta dýcha", 2026-09-25): the live mic level
//  behind the question screen's breathing listen bar. The driver answers with
//  eyes on the road, so "does the mic hear me?" has to be answered by something
//  visible from the corner of the eye: the whole bar glows with the voice.
//
//  Its own tiny observable on purpose. The level arrives ~47 times a second
//  (one per tap buffer, `SilenceDetectionService.makeInputLevelStream()`); on
//  the view model's `objectWillChange` that would re-render the entire question
//  screen at that rate. Only the bar's glow observes this object.
//

import Combine
import Foundation

@MainActor
final class RecordingInputLevel: ObservableObject {
    /// 0…1, smoothed — 0 whenever no answer is being recorded.
    @Published private(set) var level: Double = 0

    /// A change smaller than this is not worth a render: at ~47 samples a
    /// second the glow would otherwise redraw for movements nobody can see.
    nonisolated static let publishThreshold = 0.02

    /// The filter's own state, advanced on EVERY sample. Kept apart from the
    /// published `level` so skipping a render never stalls the filter — with
    /// one variable for both, the release tail froze just under the threshold
    /// and the glow never settled back to quiet (PR #201 review).
    private var filtered: Double = 0

    /// Feed one tap buffer's level (`InputLevel.normalized`, 0…1).
    func ingest(_ sample: Double) {
        filtered = Self.smoothed(previous: filtered, sample: sample)
        guard abs(filtered - level) >= Self.publishThreshold || (filtered == 0 && level != 0) else { return }
        level = filtered
    }

    /// The recording ended: the bar must not keep glowing for a closed mic.
    func reset() {
        filtered = 0
        if level != 0 { level = 0 }
    }

    /// Fast attack, slow release — the glow jumps with a syllable and fades
    /// between words instead of flickering off at every consonant gap.
    /// Pure so the feel is assertable without an audio device.
    nonisolated static func smoothed(previous: Double, sample: Double) -> Double {
        let target = min(max(sample, 0), 1)
        let rate = target > previous ? 0.6 : 0.2
        let next = previous + (target - previous) * rate
        // Snap the tail to zero so a silent mic settles on "quiet", not 0.003.
        return next < 0.01 ? 0 : next
    }
}
