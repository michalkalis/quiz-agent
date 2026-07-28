//
//  CmdListenBar.swift
//  Hangs
//
//  Issue #77 (voice commands), task 77.12 — the on-screen listening cue.
//  Rendered exactly when the screen-scoped command listener is armed and
//  actively listening (QuizViewModel.commandListenerHint != nil), so a driver
//  gets a visible signal of *when* the recognizer is live and *which* words are
//  valid on this screen. #122 Track A adds the transient feedback tint (lit /
//  lit-miss) and renders the caption in the COMMAND language (#120 rule — it
//  was hardcoded English). Purely presentational — the arming lifecycle is
//  owned by QuizViewModel+CommandListener. Design: pen component `s49sd`.
//

import SwiftUI

/// Teal-tinted listening indicator: an animated waveform + a localized
/// "LISTENING FOR COMMANDS" caption over a per-screen hint ("Say \"start\"").
/// Caption and hint follow the COMMAND language (#120), independent of the app
/// locale. `feedback` transiently re-tints the bar per #122 Variant C.
struct CmdListenBar: View {
    /// Per-screen hint text (e.g. `Say "start"`), supplied by
    /// `VoiceCommandLexicon.hint(on:)` in the command language.
    let hint: String

    /// #122 Variant C: transient feedback tint — `.matched` brightens the bar
    /// teal ("lit"), `.unmatched` re-tints it amber ("lit-miss"). Cosmetic
    /// only; the bar keeps its size, slot and caption in every phase.
    var feedback: VoiceFeedbackPhase = .idle

    /// Command language for the caption — injectable for tests, defaults to
    /// the launch-time engine selection (same pattern as the lexicon).
    var language: CommandLanguage = CommandEngineSelection.current.commandLanguage

    private var teal: Color { Theme.Hangs.Colors.accentTeal }
    private var amber: Color { Theme.Hangs.Colors.warning }

    /// Caption/waveform/dots tint: amber only while showing the miss state.
    private var accent: Color { feedback == .unmatched ? amber : teal }

    private var fill: Color {
        switch feedback {
        case .idle: return teal.opacity(0.08)
        case .matched: return teal.opacity(0.22)
        case .unmatched: return amber.opacity(0.12)
        }
    }

    private var border: Color {
        switch feedback {
        case .idle: return teal.opacity(0.35)
        case .matched: return teal.opacity(0.75)
        case .unmatched: return amber.opacity(0.55)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                    .accessibilityHidden(true)

                Text(verbatim: VoiceCommandLexicon.listeningCaption(language: language))
                    .font(.hangsMonoMini)
                    .tracking(1.5)
                    .foregroundColor(accent)

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
                .fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: feedback)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(VoiceCommandLexicon.listeningCaption(language: language)). \(hint)"))
        .accessibilityIdentifier("cmd-listen-bar")
    }

    // Three trailing dots, fading back like the pen (opacity 1 · 0.55 · 0.3).
    private var dots: some View {
        HStack(spacing: 4) {
            ForEach(Array([1.0, 0.55, 0.3].enumerated()), id: \.offset) { _, opacity in
                Circle()
                    .fill(accent)
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
            CmdListenBar(hint: #"Say "start" or "skip""#, feedback: .matched)
            CmdListenBar(hint: #"Povedz „štart""#, feedback: .unmatched, language: .slovak)
        }
        .padding(24)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
