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
    /// False = the command window is not armed (or the recognizer is not ready)
    /// — the bar must not claim to be listening, so it is not rendered at all.
    var isListeningForCommands: Bool = false
    /// #174: the words to say under the bar, nil once the driver has outgrown
    /// them (`QuizSettings.voiceHintsVisible`) — the bar stays, the words go.
    let commandHint: String?
    /// #174: the Next button's title is its voice command — mic glyph.
    var showsVoiceGlyph: Bool = false
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
                .padding(.horizontal, 4)

            if isListeningForCommands {
                ListenBar(mode: .command, feedback: feedbackPhase, commandHint: commandHint, language: commandLanguage)
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
                    height: 64,
                    voiceGlyph: showsVoiceGlyph,
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
