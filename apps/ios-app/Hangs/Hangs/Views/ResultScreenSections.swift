//
//  ResultScreenSections.swift
//  Hangs
//
//  Result-screen zones — the verdict state, its label, and the small
//  meta row. The answer block lives in ResultAnswerPanel.swift, the footer in
//  ResultFooter.swift.
//
//  #224 (founder, TF 2026-11-02, canvas B1b): the result is calm. One neutral
//  card, the verdict said once in its header (green only when right), the
//  answer big, the rest quiet.
//
//  The #127 zero-scroll rule still holds: card and footer are fixed zones;
//  only the explanation scrolls, inside the card.
//

import SwiftUI

/// Verdict state driving the label. `.neutral` is the defensive
/// nil-evaluation rendering, no label (never a blank screen, never a confident
/// verdict over an answer we lack).
enum ResultVerdict {
    case correct
    case incorrect
    case neutral
    /// #131 Track D: a skip is not a failure, distinct from `.incorrect` so it
    /// never reads "Missed" over an answer the driver never gave.
    case skipped

    /// The verdict word (nil = neutral, no word).
    var word: LocalizedStringKey? {
        switch self {
        case .correct: return "Nailed it"
        case .incorrect: return "Missed"
        case .skipped: return "Skipped"
        case .neutral: return nil
        }
    }

    /// The label glyph (nil = neutral, no label).
    var symbol: String? {
        switch self {
        case .correct: return "checkmark"
        case .incorrect: return "xmark"
        case .skipped: return "minus"
        case .neutral: return nil
        }
    }
}

// MARK: - Verdict label (#224, B1b)

/// The verdict, said once and quietly in the card's header: a glyph and a word.
/// Green only for a right answer; a miss and a skip stay in the muted text
/// colour (a wrong answer reads neutral, never red).
struct ResultVerdictLabel: View {
    let verdict: ResultVerdict

    var body: some View {
        if let word = verdict.word, let symbol = verdict.symbol {
            HStack(spacing: Theme.Hangs.Spacing.xxs) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(word)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("result.verdict")
            }
            .font(.hangsBody.weight(.semibold))
            .foregroundStyle(verdict == .correct ? Theme.Hangs.Colors.successText : Theme.Hangs.Colors.muted)
            .lineLimit(1)
        }
    }
}

// MARK: - Meta row

/// The small last row of the card: the TestFlight review badge and (daily
/// challenge) how the others did on the left, the source link on the right.
struct ResultMetaRow: View {
    let sourceDomain: String?
    /// #205: how the other players did, daily challenge only.
    var crowd: CrowdStrip? = nil
    var reviewBadge: String? = nil
    /// #155 TestFlight-only: the reviewer's note, under the row.
    var reviewNote: String? = nil
    /// The card's text colour, so the link reads on any category fill.
    var tint: Color = Theme.Hangs.Colors.muted
    let onOpenSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                if let reviewBadge {
                    ReviewBadge(badge: reviewBadge, filled: true)
                        .fixedSize()
                        .accessibilityIdentifier("result.reviewBadge")
                }
                if let crowd {
                    CrowdStripRow(strip: crowd)
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
        // .contain: the row is its own element and the crowd line, source link and
        // badge inside keep their own identifiers (a bare container id replaces them).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("result.metaRow")
    }
}
