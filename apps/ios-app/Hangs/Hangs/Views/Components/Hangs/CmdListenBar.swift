//
//  CmdListenBar.swift
//  Hangs
//
//  Issue #77 (voice commands), task 77.12 — the on-screen "LISTENING FOR
//  COMMANDS" cue. Rendered exactly when the screen-scoped command listener is
//  armed and actively listening (QuizViewModel.commandListenerHint != nil), so a
//  driver gets a visible signal of *when* the recognizer is live and *which*
//  words are valid on this screen. Purely presentational — the arming lifecycle
//  is owned by QuizViewModel+CommandListener. Design: pen component `s49sd`.
//

import SwiftUI

/// Teal-tinted listening indicator: an animated waveform + "LISTENING FOR
/// COMMANDS" caption over a per-screen hint ("Say \"start\""). The command
/// grammar is English-only by design, so `hint` is rendered verbatim.
struct CmdListenBar: View {
    /// Per-screen hint text (e.g. `Say "start"`), supplied by
    /// `VoiceCommandLexicon.hint(on:)`. English by design.
    let hint: String

    private var teal: Color { Theme.Hangs.Colors.accentTeal }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(teal)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                    .accessibilityHidden(true)

                Text(verbatim: "LISTENING FOR COMMANDS")
                    .font(.hangsMonoMini)
                    .tracking(1.5)
                    .foregroundColor(teal)

                dots
            }

            Text(verbatim: hint)
                .font(.hangsBody(13, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(teal.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(teal.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Listening for commands. \(hint)"))
        .accessibilityIdentifier("cmd-listen-bar")
    }

    // Three trailing dots, fading back like the pen (opacity 1 · 0.55 · 0.3).
    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(Array([1.0, 0.55, 0.3].enumerated()), id: \.offset) { _, opacity in
                Circle()
                    .fill(teal)
                    .frame(width: 5, height: 5)
                    .opacity(opacity)
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        CmdListenBar(hint: #"Say "start""#)
        CmdListenBar(hint: #"Say "ok", "again" or "stop""#)
    }
    .padding(24)
    .background(Theme.Hangs.Colors.bg)
}
#endif
