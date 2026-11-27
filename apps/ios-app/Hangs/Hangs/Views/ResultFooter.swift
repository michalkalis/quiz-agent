//
//  ResultFooter.swift
//  Hangs
//
//  The result screen's fixed footer (issue #127): the "Next" CTA with the
//  auto-advance countdown. #224 (founder, TF 2026-11-02): no voice commands
//  here, so no listening bar and no glow line. TF build 90 (C1): the STAY/RESUME
//  pill is gone, the toolbar's pause holds and resumes the countdown.
//

import SwiftUI

struct ResultFooter: View {
    /// True while auto-advance is counting down (drives the CTA countdown).
    let autoAdvanceActive: Bool
    let countdownRemaining: Int
    let countdownTotal: Int
    /// #251 (founder TF 2026-11-27): the countdown is held while the verdict
    /// and explanation are read. "3s" then promised a move the app was not
    /// making; the seconds show once they really count down.
    var countdownHeld: Bool = false

    let onNext: () -> Void

    /// Whether the button shows the seconds left.
    var showsSeconds: Bool { autoAdvanceActive && !countdownHeld }

    var body: some View {
        // #174: "Next" — the title IS the voice command (founder
        // 2026-09-09: imperative button names, one word seen = one word
        // said). The a11y label keeps the fuller "Next question".
        HangsPrimaryButton(
            title: "Next",
            icon: nil,
            trailingIcon: "arrow.right",
            countdownSecondsRemaining: autoAdvanceActive ? countdownRemaining : nil,
            countdownTotal: countdownTotal,
            showsCountdownSeconds: showsSeconds,
            action: onNext
        )
        .accessibilityLabel(showsSeconds
            ? Text("Next question, auto-advancing in \(countdownRemaining) seconds", comment: "Accessibility label for the next-question button while auto-advance counts down")
            : Text("Next", comment: "Accessibility label for the next-question button"))
        .accessibilityIdentifier("result.continue")
        // #194 canvas: the screen's 16pt edge.
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }
}
