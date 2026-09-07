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
//                    shown while a command window is armed.
//   - `.answer`   — pink, "LISTENING — SAY A–D / TRUE OR FALSE / YOUR ANSWER",
//                    app-locale localized, shown while answering.
//
//  Match/no-match feedback follows #122 Variant C (teal sweep / amber breath) in
//  both modes and re-tints the bar (lit / lit-miss).
//
//  #131 Track F, Option B "full + slim" (founder pick 2026-07-29): this is now
//  the ONLY listening bar in the app — `CmdListenBar` is retired, Home /
//  Confirmation / Result all render this one. A `size` parameter is the single
//  fork allowed: `.full` (~56pt, caption over the words) on quiz screens, `.slim`
//  (~40pt, short caption + words on ONE row) on Home, where the command never
//  changes and the screen has content to show.
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
//  #132 Track B, variant A "odpočet v lište" (founder pick 2026-07-29): the MCQ
//  think-phase countdown lives IN this bar — command mode gains an optional
//  `thinkCountdown`: a teal fill anchored left drains leftwards as the window
//  empties and the caption counts the seconds down. At zero the call site swaps
//  the mode to `.answer`, so one element carries both states (nothing appears or
//  disappears). The command-word sub-line stays exactly as every other command
//  bar renders it — the founder's correction to the mock, which had dropped it.
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

    /// #131 Track F Option B — the one permitted variation. Same colours, same
    /// states, same component; only the height and the row layout differ.
    enum Size {
        case full // quiz screens: caption row over the words to say
        case slim // Home: short caption + the words on a single ~40pt row
    }

    /// #132 Track B — the think-phase window this bar is counting down. The fill
    /// fraction is `remaining/total`; a zero total hides the fill (no window is
    /// draining, e.g. while the question is still being read).
    struct ThinkCountdown: Equatable {
        let remaining: Int
        let total: Int
    }

    let mode: Mode

    /// #122 Variant C transient tint — overrides the mode accent while live.
    var feedback: VoiceFeedbackPhase = .idle

    /// The screen's concrete command words, already rendered by
    /// `VoiceCommandLexicon.hint(on:language:)` (the same string the caller gates
    /// the bar on). Command mode only; nil keeps the bar single-line.
    var commandHint: String? = nil

    /// Full on quiz screens, slim on Home (#131 Track F).
    var size: Size = .full

    /// Command-mode caption language (#120) — independent of the app/quiz locale.
    var language: CommandLanguage = CommandEngineSelection.current.commandLanguage

    /// #132 Track B: MCQ think-phase countdown. Command mode only — answer mode
    /// ignores it (the mic is already live, there is nothing left to count down).
    var thinkCountdown: ThinkCountdown? = nil

    /// The countdown, iff the mode can host one.
    private var activeThinkCountdown: ThinkCountdown? {
        guard case .command = mode else { return nil }
        return thinkCountdown
    }

    /// Left-anchored drain fraction, nil when no window is running.
    private var thinkFillFraction: CGFloat? {
        guard let countdown = activeThinkCountdown, countdown.total > 0 else { return nil }
        return min(max(CGFloat(countdown.remaining) / CGFloat(countdown.total), 0), 1)
    }

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

    /// Background fill — matched/unmatched are the #122 lit /
    /// lit-miss tints; idle uses the mode's soft accent.
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

    private var barHeight: CGFloat { Self.height(size: size, hasSubLine: subLine != nil) }

    /// Pure so the founder-picked sizes (full ~56 with the words, slim ~40) are
    /// assertable without rendering. Internal for tests.
    static func height(size: Size, hasSubLine: Bool) -> CGFloat {
        switch size {
        case .slim: return 40
        case .full: return hasSubLine ? 56 : 44
        }
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
    /// With a think countdown the caption counts the window down instead —
    /// catalog-localized like the answer captions, since it narrates the answer
    /// flow ("listening in N s"), not the command engine.
    private var captionText: Text {
        if let countdown = activeThinkCountdown {
            return Text("THINK — LISTENING IN \(countdown.remaining) S")
        }
        switch mode {
        case .command:
            return Text(verbatim: VoiceCommandLexicon.listeningCaption(
                language: language,
                short: size == .slim
            ))
        case let .answer(kind):
            switch kind {
            // #171 Track I: answering with the option TEXT works (and now goes
            // through the confirmation sheet like every other answer), so the
            // caption must say so — "say A–D" read as letters-only.
            case .mcq: return Text("Listening — say A–D or the answer")
            case .trueFalse: return Text("LISTENING — SAY TRUE OR FALSE")
            case .open: return Text("LISTENING — SAY YOUR ANSWER")
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Clock while a think window drains, live waveform once listening —
            // the mock's two glyphs for the two states of the one bar (#132 B).
            Image(systemName: activeThinkCountdown == nil ? "waveform" : "clock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(accent)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                              isActive: activeThinkCountdown == nil)
                .accessibilityHidden(true)

            switch size {
            case .full:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        caption
                        dots
                    }
                    words
                }
            case .slim:
                // One row: the short caption and the words share the 40pt bar.
                caption
                dots
                words
            }

            Spacer(minLength: 8)
        }
        // Combined so VoiceOver reads one "listening … say X" element.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subLine.map { captionText + Text(verbatim: ". ") + $0 } ?? captionText)
        .accessibilityIdentifier("listen-bar")
        .padding(.leading, size == .slim ? 16 : 18)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity)
        .frame(height: barHeight)
        .background(
            ZStack(alignment: .leading) {
                Capsule().fill(fill)
                // #132 B: the draining think window — right edge retreats
                // leftwards each tick ("vyprázdňuje sa doľava").
                if let fraction = thinkFillFraction {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(teal.opacity(0.14))
                            .frame(width: geo.size.width * fraction)
                            .animation(.linear(duration: 1), value: fraction)
                    }
                    .clipShape(Capsule())
                }
            }
        )
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.25), value: feedback)
    }

    // MARK: - Parts

    private var caption: some View {
        captionText
            .font(.hangsMono(12, weight: .medium))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundColor(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The words to say. Command mode only — answer mode's caption IS the
    /// instruction. Never wraps: it must stay one glanceable line at 40pt too.
    @ViewBuilder
    private var words: some View {
        if let subLine {
            subLine
                .font(.hangsBody(12, weight: .medium))
                .foregroundColor(accent.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier("listen-bar.commands")
        }
    }

    /// Three trailing dots fading back (opacity 1 · 0.55 · 0.3) — the "live mic"
    /// tell migrated from `CmdListenBar` when it was retired (#131 Track F).
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
            ListenBar(mode: .command, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, commandHint: #"Say "start" or "skip""#,
                      thinkCountdown: .init(remaining: 32, total: 45))
            ListenBar(mode: .command, feedback: .matched, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, feedback: .unmatched, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .answer(.mcq))
            ListenBar(mode: .answer(.trueFalse), feedback: .unmatched)
            ListenBar(mode: .answer(.open))
            ListenBar(mode: .command, commandHint: #"Povedz „štart" alebo „preskoč""#, language: .slovak)
            ListenBar(mode: .command, commandHint: #"Say "start""#, size: .slim)
            ListenBar(mode: .command, feedback: .unmatched, commandHint: #"Povedz „štart""#,
                      size: .slim, language: .slovak)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
