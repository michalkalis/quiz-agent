//
//  ResultFooter.swift
//  Hangs
//
//  The result screen's fixed footer (issue #127, unchanged by the #131 Track D
//  pick): docked GlowSweepLine (rule V1) + the listening bar + ONE row with the
//  "Next question" CTA primary-left and the STAY/RESUME pill to its right.
//  #131 Track F: the bar is the shared `ListenBar` (full size — this is a quiz
//  screen); `CmdListenBar` is retired.
//

import SwiftUI

struct ResultFooter: View {
    let feedbackPhase: VoiceFeedbackPhase
    /// nil = the command window is not armed (or the recognizer is not ready) —
    /// the bar must not claim to be listening, so it is not rendered at all.
    let commandHint: String?
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
            // #122/rule V1: light sweep strip, docked above the bar — reserves its
            // 4 pt in every phase so the bar never shifts.
            GlowSweepLine(phase: feedbackPhase)
                .padding(.horizontal, 4)

            if let commandHint {
                ListenBar(mode: .command, feedback: feedbackPhase, commandHint: commandHint)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                // #131 Track D: primary CTA sits LEFT, STAY/RESUME to its right
                // (founder spec, swapped from the #127 layout).
                HangsPrimaryButton(
                    title: "Next question",
                    icon: nil,
                    trailingIcon: "arrow.right",
                    height: 64,
                    countdownSecondsRemaining: autoAdvanceActive ? countdownRemaining : nil,
                    countdownTotal: countdownTotal,
                    action: onNext
                )
                .accessibilityLabel(autoAdvanceActive
                    ? Text("Next question, auto-advancing in \(countdownRemaining) seconds", comment: "Accessibility label for the next-question button while auto-advance counts down")
                    : Text("Next question", comment: "Accessibility label for the next-question button"))
                .accessibilityIdentifier("result.continue")
                stayPill
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
    }

    /// Pause glyph + STAY while the countdown runs (tap pauses); play glyph +
    /// RESUME once paused (tap resumes). Same 76pt slot — never a stacked button.
    private var stayPill: some View {
        Button(action: isPaused ? onResume : onStay) {
            VStack(spacing: 3) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                Text(isPaused ? "RESUME" : "STAY")
                    .font(.hangsMono(10, weight: .medium))
                    .tracking(1.4)
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 76, height: 64)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cta, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cta, style: .continuous)
                    .strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.stayHere")
        .accessibilityLabel(isPaused
            ? Text("Resume auto-advance", comment: "Accessibility label for the result footer pill when paused")
            : Text("Stay on this result", comment: "Accessibility label for the result footer pill while counting down"))
    }
}
