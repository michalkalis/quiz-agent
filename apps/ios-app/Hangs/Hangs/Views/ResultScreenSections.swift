//
//  ResultScreenSections.swift
//  Hangs
//
//  Result-screen zones — the verdict state, its label, and the small
//  meta row. The answer block lives in ResultAnswerPanel.swift, the footer in
//  ResultFooter.swift.
//
//  #224 (founder, TF 2026-11-02, canvas B1b): the result is calm. One neutral
//  card, the answer big, the rest quiet. #248.2 (founder 2026-11-25, variant A):
//  the verdict is the card's headline, no category on the card.
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
    /// never reads "Wrong" over an answer the driver never gave.
    case skipped

    /// The verdict word (nil = neutral, no word).
    var word: LocalizedStringKey? {
        switch self {
        case .correct: return "Correct"
        case .incorrect: return "Wrong"
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

// MARK: - Verdict label (#248.2, variant A "verdict as the headline")

/// The verdict over the answer: a small bold word with its glyph (#249,
/// variant A: the player's answer is the headline now, founder 2026-11-26).
/// Green for right, the miss pink for wrong, muted for a skip.
struct ResultVerdictLabel: View {
    let verdict: ResultVerdict
    /// #240.9: right answers in a row this round, said beside "Correct" from 3.
    var streak: Int? = nil

    var body: some View {
        if let word = verdict.word, let symbol = verdict.symbol {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(word)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("result.verdict")
                if let streak {
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Text("\(streak) in a row")
                        .accessibilityIdentifier("result.streak")
                }
            }
            .font(.hangsBody.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
    }

    private var color: Color {
        switch verdict {
        case .correct: Theme.Hangs.Colors.successText
        case .incorrect: Theme.Hangs.Colors.missText
        case .skipped, .neutral: Theme.Hangs.Colors.muted
        }
    }
}

// MARK: - Meta row

/// The small last row of the card: "Show question" on the left, the source
/// link on the right (TF build 90, C1). The TestFlight review badge and (daily
/// challenge) how the others did sit on their own line above it.
struct ResultMetaRow: View {
    let sourceDomain: String?
    /// #205: how the other players did, daily challenge only.
    var crowd: CrowdStrip? = nil
    var reviewBadge: String? = nil
    /// #155 TestFlight-only: the reviewer's note, under the row.
    var reviewNote: String? = nil
    /// The card's text colour, so the link reads on any category fill.
    var tint: Color = Theme.Hangs.Colors.muted
    /// Opens the question sheet; nil hides the control (recap: the question is on the card).
    var onShowQuestion: (() -> Void)? = nil
    let onOpenSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            if reviewBadge != nil || crowd != nil {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    if let reviewBadge {
                        ReviewBadge(badge: reviewBadge, filled: true)
                            .fixedSize()
                            .accessibilityIdentifier("result.reviewBadge")
                    }
                    if let crowd {
                        CrowdStripRow(strip: crowd)
                    }
                }
            }
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                if let onShowQuestion {
                    ResultCardChip(title: "Show question", systemImage: "doc.text", action: onShowQuestion)
                        .accessibilityIdentifier("result.showQuestion")
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

// MARK: - Card chip

/// A quiet capsule action on the result card ("hear it", "Show question").
struct ResultCardChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    private enum Metrics {
        static let height: CGFloat = 32
    }

    var body: some View {
        // a11y-id: call-site
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .lineLimit(1)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .frame(minHeight: Metrics.height)
            .background(Capsule().fill(Theme.Hangs.Colors.bgInset))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card surface

/// The calm result card's plate (#224) without the category header row the
/// question's `HangsDeckCard` carries: #248.2 opens the result with the verdict
/// as its headline and prints no category. Same plate, corner and padding as the
/// calm deck card.
struct ResultCardSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
        content()
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 18, trailing: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                shape.fill(Theme.Hangs.Colors.bgCard)
                    .overlay(shape.strokeBorder(Theme.Hangs.Colors.hairline, lineWidth: 1))
            )
    }
}
