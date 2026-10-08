//
//  ResultScreenSections.swift
//  Hangs
//
//  Result-screen zones — the verdict state, the dominant verdict band and the
//  single muted meta row. The answer card lives in ResultAnswerPanel.swift, the
//  footer in ResultFooter.swift.
//
//  #131 Track D, Variant A "Verdikt vládne" (founder pick 2026-07-29,
//  docs/design/ui-variants-2026-07-29-decisions.md) replaces the #127 verdict
//  field: the verdict takes a full-bleed colour band and 56pt Anton — the first
//  and only thing a driver reads at a glance — and the state is said EXACTLY
//  ONCE (the small "correct" / "not quite" chip is gone; the word already says
//  it). Everything secondary — score, streak, what you said, the source —
//  collapses into ONE 10pt mono row under the card.
//
//  The #127 zero-scroll rule still holds: band, card, meta row and footer are
//  fixed zones; only the explanation scrolls, inside the card.
//

import SwiftUI

/// Verdict state driving the band tint / badge / word. `.neutral` is the
/// defensive nil-evaluation rendering — a band with no word and no badge
/// (never a blank screen, never a confident verdict over an answer we lack).
enum ResultVerdict {
    case correct
    case incorrect
    case neutral
    /// #131 Track D: a skip is not a failure — distinct from `.incorrect` so it
    /// never renders "MISSED IT." over an answer the driver never gave. Neutral
    /// palette, own headline ("SKIPPED."), no "you said" entry in the meta row.
    case skipped

    /// The badge kind (nil = neutral/skipped — skipped draws its own neutral
    /// dash badge, neutral draws none).
    var kind: HangsResultKind? {
        switch self {
        case .correct: return .correct
        case .incorrect: return .incorrect
        case .neutral, .skipped: return nil
        }
    }

    /// The Anton verdict word (nil = neutral, no word).
    var word: LocalizedStringKey? {
        switch self {
        case .correct: return "NAILED IT."
        case .incorrect: return "MISSED IT."
        case .skipped: return "SKIPPED."
        case .neutral: return nil
        }
    }

    /// Band wash: greenSoft / pinkSoft tint. Skipped and neutral take the
    /// neutralSoft wash — a white band was indistinguishable from the page, so
    /// the band stopped reading as a band at all on a skip (sim check).
    var fieldFill: Color {
        switch self {
        case .correct: return Theme.Hangs.Colors.greenSoft
        case .incorrect: return Theme.Hangs.Colors.actionSoft
        case .neutral, .skipped: return Theme.Hangs.Colors.neutralSoft
        }
    }

    /// Full ink for every verdict: a muted "SKIPPED" on the grey band was
    /// near unreadable in light mode (#188 G14); the band wash already says
    /// a skip is neutral news.
    var wordColor: Color { Theme.Hangs.Colors.ink }

    /// Skipped's word is a longer token, so it drops a step to stay one line
    /// (the big-Anton single-line rule) without relying on scale-down alone.
    var wordSize: CGFloat { self == .skipped ? 44 : 56 }
}

// MARK: - Verdict band

/// Full-bleed colour band: the state badge over the Anton verdict word. No
/// status chip — Variant A says the state exactly once. #132: the replay-the-
/// question speaker left the band; the WHY card's "hear it" is the one replay
/// affordance on this screen.
struct ResultVerdictBand: View {
    let verdict: ResultVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                badge
                Spacer()
            }
            if let word = verdict.word {
                Text(word)
                    .font(.hangsDisplay(verdict.wordSize))
                    .tracking(-2.4)
                    .foregroundColor(verdict.wordColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("result.verdict")
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.xl)
        .padding(.top, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Edge-to-edge: the band IS the hierarchy, so it is not a card.
        .background(verdict.fieldFill)
    }

    /// Small state badge: check / x from the shared tokens; skipped gets a
    /// neutral dash (it has no HangsResultKind counterpart).
    @ViewBuilder
    private var badge: some View {
        if let kind = verdict.kind {
            HangsInlineBadge(kind: kind, size: 22)
                .accessibilityIdentifier("result.heroBanner")
        } else if verdict == .skipped {
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.Hangs.Colors.textOnAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.Hangs.Colors.mutedFaint))
                .accessibilityIdentifier("result.heroBanner")
        }
    }
}

// MARK: - Meta row

/// The ONE quiet row under the answer card, in 10pt mono, faintest grey: what
/// the driver said when it was wrong, and the source link. #132: score and
/// streak are gone from the result screen entirely (founder — a per-question
/// score echo is noise, and the row is the last place they still lived).
struct ResultMetaRow: View {
    /// The wrong answer, struck through. nil on correct/skipped — a skip has
    /// nothing the driver said (#131 Track D).
    let userAnswer: String?
    /// Host of the source URL ("nasa.gov"); nil hides the source link.
    let sourceDomain: String?
    /// #176 review badge, already gated to TestFlight/Debug by the caller; nil
    /// in an App Store build, so the row is byte-identical to pre-#176 there.
    var reviewBadge: String? = nil
    /// What the gate objected to — its own line, because it is a sentence and
    /// the row above it is a row of labels.
    var reviewNote: String? = nil
    let onOpenSource: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            // #188 G9 (D10 rule, founder screenshot at large text): the driver's
            // own answer is never cut to "…" — it wraps. At enlarged text it also
            // takes its own line and the badge and source move under it, so it
            // is not squeezed into a sliver beside them.
            let layout = dynamicTypeSize > .large
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs))
            layout {
                if let userAnswer, !userAnswer.isEmpty { saidEntry(userAnswer) }
                HStack(spacing: Theme.Hangs.Spacing.xs) { labels }
            }
            if let reviewNote {
                Text(verbatim: reviewNote)
                    .font(.hangsMono(10, weight: .medium))
                    // A sentence: it wraps rather than ending in "…" (#188 G9).
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("result.reviewNote")
            }
        }
        .foregroundColor(Theme.Hangs.Colors.mutedFaint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("result.metaRow")
    }

    /// Badge, then the source link at the trailing edge.
    @ViewBuilder
    private var labels: some View {
        if let reviewBadge {
            ReviewBadge(badge: reviewBadge, filled: true)
                .fixedSize()
                .accessibilityIdentifier("result.reviewBadge")
        }
        Spacer(minLength: 8)
        if let sourceDomain {
            // #179: the same link the recap's expanded row draws.
            HangsSourceLink(domain: sourceDomain, action: onOpenSource)
                .accessibilityIdentifier("result.source")
        }
    }

    /// The label is `.fixedSize()`: without it SwiftUI shares the squeeze and the
    /// row degrades to "you s… Saturn" (sim check, long-answer case).
    /// #188 G9: the answer is never truncated either — it wraps, and takes its
    /// width before the spacer does.
    private func saidEntry(_ answer: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            monoLabel("you said")
            Text(verbatim: answer)
                .font(.hangsMono(10, weight: .medium))
                .strikethrough()
                .fixedSize(horizontal: false, vertical: true)
        }
        .layoutPriority(1)
    }

    private func monoLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.hangsMono(10, weight: .medium))
            .tracking(1.2)
            .lineLimit(1)
            .fixedSize()
    }
}
