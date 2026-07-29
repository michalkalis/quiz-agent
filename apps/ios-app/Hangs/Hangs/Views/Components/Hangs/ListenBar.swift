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
//
//  #131 Track C (founder, 2026-07-29):
//   - NO mute button. It was a duplicate of the question audio strip's (#85), and
//     the strip is the one place a driver learns to reach for. The strip is now
//     rendered in every state this bar shows in.
//   - Command mode carries a SUB-LINE with the actual words to say, sourced from
//     `VoiceCommandLexicon.hint(on:language:)` via the caller — "LISTENING FOR
//     COMMANDS" alone never told anyone what a command is.
//   - The amber no-match state swaps that sub-line for a corrective hint. Colour
//     alone is not feedback: a driver glancing at an amber bar must read what to
//     do differently, not infer it.
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

    /// The screen's concrete command words, already rendered by
    /// `VoiceCommandLexicon.hint(on:language:)` (the same string the caller gates
    /// the bar on). Command mode only; nil keeps the bar single-line.
    var commandHint: String? = nil

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

    private var barHeight: CGFloat {
        guard subLine != nil else { return compact ? 40 : 44 }
        return compact ? 50 : 56
    }

    /// The sub-line under the caption: the words to say, or — on a no-match — a
    /// corrective hint that still names them. Answer mode has none (the caption
    /// already IS the instruction).
    private var subLine: Text? {
        guard case .command = mode, let commandHint else { return nil }
        switch feedback {
        case .unmatched:
            return Text("Didn't catch that. \(commandHint)")
        case .idle, .matched:
            return Text(verbatim: commandHint)
        }
    }

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
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(accent)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                captionText
                    .font(.hangsMono(12, weight: .medium))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if let subLine {
                    subLine
                        .font(.hangsBody(12, weight: .medium))
                        .foregroundColor(accent.opacity(0.9))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityIdentifier("listen-bar.commands")
                }
            }

            Spacer(minLength: 8)
        }
        // Combined so VoiceOver reads one "listening … say X" element.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subLine.map { captionText + Text(verbatim: ". ") + $0 } ?? captionText)
        .accessibilityIdentifier("listen-bar")
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: barHeight)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: feedback)
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 16) {
            ListenBar(mode: .command, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, feedback: .matched, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, feedback: .unmatched, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .answer(.mcq))
            ListenBar(mode: .answer(.trueFalse), feedback: .unmatched)
            ListenBar(mode: .answer(.open))
            ListenBar(mode: .command, commandHint: #"Povedz „štart" alebo „preskoč""#, language: .slovak)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
