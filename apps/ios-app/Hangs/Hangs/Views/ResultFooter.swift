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
    var recognizingWord: String? = nil
    /// False = the command window is not armed (or the recognizer is not ready)
    /// — the bar must not claim to be listening, so it is not rendered at all.
    var isListeningForCommands: Bool = false
    /// #174: the words to say under the bar, nil once the driver has outgrown
    /// them (`QuizSettings.voiceHintsVisible`) — the bar stays, the words go.
    let commandHint: String?
    /// #175: the command language (= quiz language) for the bar's caption.
    var commandLanguage: CommandLanguage = .english
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
                .padding(.horizontal, Theme.Hangs.Spacing.xxs)

            if isListeningForCommands {
                ListenBar(mode: .command, feedback: feedbackPhase, recognizingWord: recognizingWord, commandHint: commandHint, language: commandLanguage)
                    .transition(.opacity)
            }

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
