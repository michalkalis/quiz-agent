//
//  ResultScreenSections.swift
//  Hangs
//
//  Issue #127 — Result-screen redesign, Variant C "Zero-Scroll Deck" (founder
//  pick 2026-07-28, docs/design/ui-variants-2026-07-28-decisions.md). The three
//  fixed zones of the result screen, extracted from ResultView so the parent
//  stays navigable: a colour-washed verdict field, an answer panel that fills
//  the remaining space (with the explanation scrolling INSIDE it per the founder
//  modification — the screen chrome never scrolls), and a consolidated footer.
//

import SwiftUI

/// Verdict state driving the field tint / chip / word. `.neutral` is the
/// defensive nil-evaluation rendering — a field with only the running score,
/// no chip and no verdict word (never a blank screen).
enum ResultVerdict {
    case correct
    case incorrect
    case neutral

    /// The banner kind (nil = neutral, no chip).
    var kind: HangsResultKind? {
        switch self {
        case .correct: return .correct
        case .incorrect: return .incorrect
        case .neutral: return nil
        }
    }

    /// The Anton verdict word (nil = neutral, no word).
    var word: LocalizedStringKey? {
        switch self {
        case .correct: return "NAILED IT."
        case .incorrect: return "MISSED IT."
        case .neutral: return nil
        }
    }

    /// Field wash: greenSoft / pinkSoft tint; neutral falls back to a plain card.
    var fieldFill: Color {
        switch self {
        case .correct: return Theme.Hangs.Colors.greenSoft
        case .incorrect: return Theme.Hangs.Colors.pinkSoft
        case .neutral: return Theme.Hangs.Colors.bgCard
        }
    }
}

// MARK: - Verdict field

/// Colour-washed field: [verdict chip + inline scorebox] over the Anton verdict
/// word at 30pt. Reuses the HangsResultKind tokens; keeps the single-line rule.
struct ResultVerdictField: View {
    let verdict: ResultVerdict
    let scoreValue: String
    /// "+1" / "+0" delta; nil hides it (neutral / nil-evaluation).
    let scoreDelta: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                if let kind = verdict.kind {
                    HStack(spacing: 8) {
                        Image(systemName: kind.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(kind.label)
                            .font(.hangsMono(11, weight: .medium))
                            .tracking(2)
                    }
                    .foregroundColor(kind.color)
                    .accessibilityIdentifier("result.heroBanner")
                }
                Spacer()
                scorebox
            }
            if let word = verdict.word {
                Text(word)
                    .font(.hangsDisplay(30))
                    .tracking(-1.4)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(verdict.fieldFill)
        )
    }

    private var scorebox: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text("score")
                .font(.hangsMono(10, weight: .medium))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundColor(Theme.Hangs.Colors.pink)
            Text(scoreValue)
                .font(.hangsDisplay(22))
                .tracking(-0.5)
                .foregroundColor(Theme.Hangs.Colors.ink)
            if let scoreDelta {
                Text(scoreDelta)
                    .font(.hangsBody(12, weight: .medium))
                    .foregroundColor(Theme.Hangs.Colors.muted)
            }
        }
    }
}

// MARK: - Answer panel

/// The panel that fills the remaining vertical space. Byte-identical structure
/// for correct / incorrect — only the label, the bottom row and (upstream) the
/// verdict tint change. Founder modification: the explanation scrolls INSIDE
/// this panel when it overflows; the screen chrome never scrolls.
struct ResultAnswerPanel: View {
    let verdict: ResultVerdict
    /// "your answer" (correct) / "the answer" (incorrect) / "the question" (recap).
    let answerLabel: LocalizedStringKey
    /// The 46pt answer — or, in recap mode, the question stem at a smaller size.
    let answerText: String
    /// Recap fallback (nil evaluation or empty answer): the stem is the dominant
    /// text, rendered smaller, and the bottom "you said" / "the question" rows drop.
    let isRecap: Bool
    /// Explanation text; nil omits the whole "why" block.
    let explanation: String?
    /// Question stem for the correct-answer bottom recap line ("the question · …").
    let questionStem: String?
    /// The user's answer for the incorrect bottom line ("you said · …").
    let userAnswer: String?
    /// Host of the source URL ("nasa.gov"); nil hides the source line.
    let sourceDomain: String?

    let onReadAloud: () -> Void
    let onHearIt: () -> Void
    let onOpenSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HangsSectionLabel(
                    // The answer label is green on both outcomes ("your answer" /
                    // "the answer"); the recap ("the question") reads neutral.
                    text: answerLabel,
                    color: isRecap ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.successText
                )
                Spacer()
                readAloudControl
            }

            Text(answerText)
                .font(.hangsDisplay(isRecap ? 26 : 46))
                .tracking(-1.5)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(isRecap ? 3 : 2)
                .minimumScaleFactor(0.4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

            if let explanation {
                hairline.padding(.top, 12)
                HStack {
                    HangsSectionLabel(text: "why", color: Theme.Hangs.Colors.blue)
                    Spacer()
                    hearItControl
                }
                .padding(.top, 12)
                explanationScroll(explanation)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }

            bottomRows
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .hangsShadow(Theme.Hangs.Shadow.card)
    }

    // MARK: Explanation (internal scroll, never clips the screen)

    /// The explanation scrolls WITHIN the panel when it overflows — the visible
    /// affordance is the scroll indicator plus a bottom fade into the card.
    private func explanationScroll(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(text)
                .font(.hangsBody(15))
                .lineSpacing(3)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Theme.Hangs.Colors.bgCard.opacity(0), Theme.Hangs.Colors.bgCard],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 18)
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier("result.explanation")
    }

    // MARK: Bottom recap / source rows

    @ViewBuilder
    private var bottomRows: some View {
        if isRecap {
            // Recap mode: the stem is already the dominant text; only the source
            // line (when present) survives at the bottom.
            if sourceDomain != nil {
                hairline.padding(.top, 10)
                sourceRow.padding(.top, 6)
            }
        } else {
            hairline.padding(.top, 10)
            if verdict == .correct {
                if let questionStem {
                    monoRecapLine(label: "the question", value: questionStem, struck: false)
                        .padding(.top, 10)
                }
            } else {
                HStack {
                    monoRecapLine(label: "you said", value: userAnswer ?? "", struck: true)
                    Spacer()
                    HangsInlineBadge(kind: .incorrect, size: 16)
                }
                .padding(.top, 10)
            }
            if sourceDomain != nil {
                sourceRow.padding(.top, 6)
            }
        }
    }

    /// Mono "label · value" line; `struck` renders the value strikethrough (the
    /// wrong "you said" answer). The value ellipsizes so the line never wraps.
    private func monoRecapLine(label: LocalizedStringKey, value: String, struck: Bool) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.hangsMono(10, weight: .medium))
                .tracking(1.2)
            Text(verbatim: "·")
                .font(.hangsMono(10, weight: .medium))
            Text(verbatim: value)
                .font(.hangsBody(struck ? 13 : 12, weight: .semibold))
                .strikethrough(struck)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundColor(Theme.Hangs.Colors.mutedFaint)
    }

    /// Tappable source line — opens the existing SourceWebView sheet (parked use).
    private var sourceRow: some View {
        Button(action: onOpenSource) {
            HStack(spacing: 4) {
                Text("source")
                    .font(.hangsMono(10, weight: .medium))
                    .tracking(1.2)
                Text(verbatim: "·")
                    .font(.hangsMono(10, weight: .medium))
                Text(verbatim: sourceDomain ?? "")
                    .font(.hangsMono(10, weight: .medium))
                    .tracking(1.2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.mutedFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.source")
    }

    // MARK: Controls

    private var readAloudControl: some View {
        Button(action: onReadAloud) {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                Text("read aloud")
                    .font(.hangsMono(11, weight: .medium))
                    .tracking(2)
            }
            .foregroundColor(Theme.Hangs.Colors.blue)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.readAloud")
    }

    private var hearItControl: some View {
        Button(action: onHearIt) {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                Text("hear it")
                    .font(.hangsBody(12, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.blue)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("result.hearIt")
    }

    private var hairline: some View {
        Rectangle().fill(Theme.Hangs.Colors.hairline).frame(height: 1)
    }
}

// MARK: - Footer

/// Consolidated footer: docked GlowSweepLine (rule V1) + CmdListenBar + ONE row
/// carrying a compact STAY/RESUME pill next to the "Next question" CTA. Preserves
/// the existing auto-advance wiring (pause / resume / continue) — only the
/// presentation consolidates; no state-dependent stacking.
struct ResultFooter: View {
    let feedbackPhase: VoiceFeedbackPhase
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
                CmdListenBar(hint: commandHint, feedback: feedbackPhase)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                stayPill
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
