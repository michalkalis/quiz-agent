//
//  ListenBar.swift
//  Hangs
//
//  Issue #125 Track B + the "one ListenBar, text swaps" addendum
//  (docs/design/ui-variants-2026-07-28-decisions.md). One shared full-width
//  listening bar, docked as the first footer row below GlowSweepLine, whose
//  text/accent swaps by mode — the app only ever listens for EITHER commands OR
//  an answer, never both (founder, 2026-07-28):
//
//   - `.command`  — teal, "LISTENING FOR COMMANDS" in the COMMAND language (#120),
//                    shown on voice-answer question screens while a command window
//                    is armed. Replaces the floating `CmdListenBar` pill on the
//                    question screen (CmdListenBar stays on Home/Result).
//   - `.answer`   — pink, "LISTENING — SAY A–D / TRUE OR FALSE / YOUR ANSWER",
//                    app-locale localized, shown while answering.
//
//  Match/no-match feedback follows #122 Variant C (teal sweep / amber breath) in
//  both modes and re-tints the bar exactly like CmdListenBar's lit / lit-miss.
//  The bar absorbs the mute control (audio strip drops it once the bar is on
//  screen). isMuted + the toggle come in as parameters so the component stays
//  decoupled from QuizViewModel.
//

import SwiftUI

struct ListenBar: View {
    /// The answer form the driver should speak — drives the answer-mode caption.
    enum AnswerKind {
        case mcq // multiple choice (A–D)
        case trueFalse // 2-option true/false
        case open // free-text spoken answer (recording)
    }

    /// The two listening states the bar swaps between. Never both at once.
    enum Mode {
        case command // listening for hands-free commands (teal)
        case answer(AnswerKind) // listening for an answer (pink)
    }

    let mode: Mode

    /// #122 Variant C transient tint — overrides the mode accent while live.
    var feedback: VoiceFeedbackPhase = .idle

    /// Mute state + toggle passed in (not coupled to QuizViewModel); the bar
    /// carries the same mute the audio strip used to.
    let isMuted: Bool
    let onToggleMute: () -> Void

    /// SE-class degrades the bar 44 → 40. Driven by container height, not device.
    var compact: Bool = false

    /// Command-mode caption language (#120) — independent of the app/quiz locale.
    var language: CommandLanguage = CommandEngineSelection.current.commandLanguage

    // MARK: - Tint tokens

    private var teal: Color { Theme.Hangs.Colors.accentTeal }
    private var amber: Color { Theme.Hangs.Colors.warning }
    private var pink: Color { Theme.Hangs.Colors.pink }

    /// The bar's resting accent before any feedback tint applies.
    private var modeAccent: Color {
        switch mode {
        case .command: return teal
        case .answer: return pink
        }
    }

    /// Waveform + caption colour: feedback wins over the mode accent (#122).
    private var accent: Color {
        switch feedback {
        case .idle: return modeAccent
        case .matched: return teal
        case .unmatched: return amber
        }
    }

    /// Background fill — matched/unmatched are identical to CmdListenBar's
    /// lit / lit-miss; idle uses the mode's soft accent.
    private var fill: Color {
        switch feedback {
        case .matched: return teal.opacity(0.22)
        case .unmatched: return amber.opacity(0.12)
        case .idle:
            switch mode {
            case .command: return teal.opacity(0.08)
            case .answer: return Theme.Hangs.Colors.pinkSoft
            }
        }
    }

    private var border: Color {
        switch feedback {
        case .matched: return teal.opacity(0.75)
        case .unmatched: return amber.opacity(0.55)
        case .idle:
            switch mode {
            case .command: return teal.opacity(0.35)
            case .answer: return pink
            }
        }
    }

    private var barHeight: CGFloat { compact ? 40 : 44 }

    /// Caption as a `Text`: verbatim command caption (command language) OR a
    /// catalog-localized answer prompt. Reused verbatim as the a11y label.
    private var captionText: Text {
        switch mode {
        case .command:
            return Text(verbatim: VoiceCommandLexicon.listeningCaption(language: language))
        case let .answer(kind):
            switch kind {
            case .mcq: return Text("LISTENING — SAY A–D")
            case .trueFalse: return Text("LISTENING — SAY TRUE OR FALSE")
            case .open: return Text("LISTENING — SAY YOUR ANSWER")
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accent)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                    .accessibilityHidden(true)

                captionText
                    .font(.hangsMono(12, weight: .medium))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            // Combined so VoiceOver reads one "listening …" element; the mute
            // button stays a separate, independently operable control.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(captionText)
            .accessibilityIdentifier("listen-bar")

            Spacer(minLength: 8)

            muteButton
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: barHeight)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: feedback)
    }

    /// Same toggle the audio strip's mute used — routes through the injected
    /// action so muting mid-read can still stop in-flight TTS at the call site.
    private var muteButton: some View {
        Button(action: onToggleMute) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isMuted ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Circle().stroke(Theme.Hangs.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isMuted
            ? String(localized: "Unmute", comment: "Accessibility label for the quiz mute toggle while muted")
            : String(localized: "Mute", comment: "Accessibility label for the quiz mute toggle while audible"))
        .accessibilityIdentifier("question.mute")
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 16) {
            ListenBar(mode: .command, isMuted: false, onToggleMute: {})
            ListenBar(mode: .command, feedback: .matched, isMuted: false, onToggleMute: {})
            ListenBar(mode: .answer(.mcq), isMuted: false, onToggleMute: {})
            ListenBar(mode: .answer(.trueFalse), feedback: .unmatched, isMuted: true, onToggleMute: {})
            ListenBar(mode: .answer(.open), isMuted: false, onToggleMute: {})
            ListenBar(mode: .command, isMuted: false, onToggleMute: {}, language: .slovak)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
