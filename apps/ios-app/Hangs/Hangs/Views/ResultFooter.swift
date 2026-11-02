//
//  ResultFooter.swift
//  Hangs
//
//  The result screen's fixed footer (issue #127, unchanged by the #131 Track D
//  pick): ONE row with the "Next question" CTA primary-left and the
//  STAY/RESUME pill to its right. #224 (founder, TF 2026-11-02): no voice
//  commands here, so no listening bar and no glow line — the buttons and the
//  auto-advance countdown are the whole interaction.
//

import SwiftUI

struct ResultFooter: View {
    /// True while auto-advance is counting down (drives the CTA countdown + STAY).
    let autoAdvanceActive: Bool
    let isPaused: Bool
    let countdownRemaining: Int
    let countdownTotal: Int

    let onNext: () -> Void
    let onStay: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // #131 Track D: primary CTA sits LEFT, STAY/RESUME to its right
                // (founder spec, swapped from the #127 layout).
                // #174: "Next" — the title IS the voice command (founder
                // 2026-09-09: imperative button names, one word seen = one word
                // said). The a11y label keeps the fuller "Next question".
                HangsPrimaryButton(
                    title: "Next",
                    icon: nil,
                    trailingIcon: "arrow.right",
                    countdownSecondsRemaining: autoAdvanceActive ? countdownRemaining : nil,
                    countdownTotal: countdownTotal,
                    action: onNext
                )
                .accessibilityLabel(autoAdvanceActive
                    ? Text("Next question, auto-advancing in \(countdownRemaining) seconds", comment: "Accessibility label for the next-question button while auto-advance counts down")
                    : Text("Next", comment: "Accessibility label for the next-question button"))
                .accessibilityIdentifier("result.continue")
                stayPill
            }
        }
        // #194 canvas: the screen's 16pt edge.
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    /// Pause glyph + STAY while the countdown runs (tap pauses); play glyph +
    /// RESUME once paused (tap resumes). Same 76pt slot — never a stacked button.
    private enum Metrics {
        /// R-Result: the pause pill beside the 56pt CTA.
        static let stayWidth: CGFloat = 76
        static let height: CGFloat = 56
        static let glyph: CGFloat = 16
    }

    private var stayPill: some View {
        Button(action: isPaused ? onResume : onStay) {
            VStack(spacing: 3) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.hangsBody(Metrics.glyph, weight: .semibold))
                Text(isPaused ? "RESUME" : "STAY")
                    .font(.hangsCaption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(width: Metrics.stayWidth, height: Metrics.height)
            // #194 R-Result: the second control is Liquid Glass beside the ink CTA.
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.stayHere")
        .accessibilityLabel(isPaused
            ? Text("Resume auto-advance", comment: "Accessibility label for the result footer pill when paused")
            : Text("Stay on this result", comment: "Accessibility label for the result footer pill while counting down"))
    }
}
