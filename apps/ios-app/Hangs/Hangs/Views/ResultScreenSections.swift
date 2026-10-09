//
//  ResultScreenSections.swift
//  Hangs
//
//  Result-screen zones — the verdict state, its badge and word, and the small
//  meta row. The answer block lives in ResultAnswerPanel.swift, the footer in
//  ResultFooter.swift.
//
//  #131 Track D, Variant A "Verdikt vládne": the verdict is the first and only
//  thing a driver reads at a glance, and the state is said EXACTLY ONCE.
//  #194 R-Result / R-Wrong ("Sklo nad kartami"): the verdict, the answer and
//  the explanation are printed on ONE card in the question's category colour;
//  the badge sits in the card's top-right corner where the replay glyph was.
//
//  The #127 zero-scroll rule still holds: card and footer are fixed zones;
//  only the explanation scrolls, inside the card.
//

import SwiftUI

/// Verdict state driving the badge and the word. `.neutral` is the defensive
/// nil-evaluation rendering — no word and no badge (never a blank screen, never
/// a confident verdict over an answer we lack).
enum ResultVerdict {
    case correct
    case incorrect
    case neutral
    /// #131 Track D: a skip is not a failure — distinct from `.incorrect` so it
    /// never renders "MISSED IT." over an answer the driver never gave. Neutral
    /// badge, own headline ("SKIPPED."), no "you said" entry.
    case skipped

    /// The verdict word (nil = neutral, no word).
    var word: LocalizedStringKey? {
        switch self {
        case .correct: return "NAILED IT."
        case .incorrect: return "MISSED IT."
        case .skipped: return "SKIPPED."
        case .neutral: return nil
        }
    }

    /// The badge glyph (nil = neutral, no badge).
    var symbol: String? {
        switch self {
        case .correct: return "checkmark"
        case .incorrect: return "xmark"
        case .skipped: return "minus"
        case .neutral: return nil
        }
    }
}

// MARK: - Verdict badge + word (#194)

/// The verdict badge in the card corner. Correct is a solid plate in the
/// card's text colour (the one celebratory mark); wrong and skipped are a soft
/// plate — a wrong answer reads neutral, never red (#194 B1).
struct ResultVerdictBadge: View {
    let verdict: ResultVerdict
    let style: Theme.Hangs.Category.Style

    private enum Metrics {
        static let size: CGFloat = 32
        static let glyph: CGFloat = 15
        static let softPlate = 0.2
    }

    var body: some View {
        if let symbol = verdict.symbol {
            Image(systemName: symbol)
                .font(.hangsBody(Metrics.glyph, weight: .bold))
                .foregroundStyle(verdict == .correct ? style.fill : style.text)
                .frame(width: Metrics.size, height: Metrics.size)
                .background(
                    Circle().fill(verdict == .correct ? style.text : style.text.opacity(Metrics.softPlate))
                )
                .accessibilityHidden(true)
                .accessibilityIdentifier("result.heroBanner")
        }
    }
}

/// The verdict word — display size, one line, scaled down to fit (critical
/// spot: the verdict dominates and never wraps).
struct ResultVerdictWord: View {
    let word: LocalizedStringKey

    var body: some View {
        Text(word)
            .font(.hangsDisplaySM)
            .tracking(-1)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("result.verdict")
    }
}

// MARK: - Meta row

/// The small last row of the card: the TestFlight review badge/note on the
/// left, the source link on the right. "You said" moved up into the card as
/// its own block (#194 R-Wrong: your answer AND the right one are both shown).
struct ResultMetaRow: View {
    let sourceDomain: String?
    var reviewBadge: String? = nil
    /// #155 TestFlight-only: the reviewer's note, under the row.
    var reviewNote: String? = nil
    /// The card's text colour, so the link reads on any category fill.
    var tint: Color = Theme.Hangs.Colors.mutedFaint
    let onOpenSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                if let reviewBadge {
                    ReviewBadge(badge: reviewBadge, filled: true)
                        .fixedSize()
                        .accessibilityIdentifier("result.reviewBadge")
                }
                Spacer(minLength: Theme.Hangs.Spacing.xs)
                if let sourceDomain {
                    HangsSourceLink(domain: sourceDomain, color: tint, action: onOpenSource)
                        .accessibilityIdentifier("result.source")
                }
            }
            if let reviewNote {
                Text(verbatim: reviewNote)
                    .font(.hangsCaption)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("result.reviewNote")
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Hangs.Spacing.xxl, alignment: .leading)
        .accessibilityIdentifier("result.metaRow")
    }
}
