//
//  ReviewBadge.swift
//  Hangs
//
//  #176 — the per-question review badge, Variant A (founder 2026-09-10).
//
//  The founder field-tests SK/CS translations in TestFlight and, in the game,
//  could not tell a human-vouched question from a machine-approved translation
//  — or from a machine-*rejected* one. The badge says which, in one word, in
//  the row that already names the generating model.
//
//  TestFlight/Debug only: the backend omits the fields entirely for an App Store
//  session AND the row is gated on `BuildChannel.debugSurfacesEnabled()`, so the
//  App Store build shows nothing new even if a payload ever carried them.
//

import SwiftUI

/// One badge state: the colour it reads in and the word it shows.
/// Modelled as a value, not a view, so the question row and the result meta row
/// cannot drift apart — there is exactly one mapping from wire value to look.
@MainActor
struct ReviewBadgeStyle {
    /// Raw wire value (`review_badge`), kept for the unknown-state fallback.
    let rawValue: String
    let tint: Color
    /// nil for `approved`: a vouched question gets a silent green dot, because
    /// the common case must not spend a word of the row's width (founder pick).
    let label: LocalizedStringKey?
    /// True when the backend sent a state this build has never heard of — shown
    /// raw and muted rather than hidden, so a new backend state is visible as
    /// "something changed" instead of silently vanishing.
    let isUnknown: Bool

    init(rawValue: String) {
        self.rawValue = rawValue
        switch rawValue {
        case "approved":
            tint = Theme.Hangs.Colors.greenCorrect
            label = nil
            isUnknown = false
        case "pending_review":
            tint = Theme.Hangs.Colors.warning
            label = "Needs review"
            isUnknown = false
        case "translation_flagged":
            tint = Theme.Hangs.Colors.warning
            label = "Translation · check"
            isUnknown = false
        case "translation_machine":
            tint = Theme.Hangs.Colors.accentTeal
            label = "Translation · machine"
            isUnknown = false
        case "translation_live":
            tint = Theme.Hangs.Colors.accentTeal
            label = "Translation · live"
            isUnknown = false
        case "translation_critical":
            tint = Theme.Hangs.Colors.error
            label = "Translation · critical"
            isUnknown = false
        case "en_fallback":
            tint = Theme.Hangs.Colors.muted
            label = "EN fallback"
            isUnknown = false
        default:
            tint = Theme.Hangs.Colors.muted
            label = nil
            isUnknown = true
        }
    }
}

/// The badge itself: a 6pt dot plus one uppercase mono word, tinted by urgency.
struct ReviewBadge: View {
    /// Raw `review_badge` value from the API.
    let badge: String
    /// Tinted capsule behind the badge (result meta row); the question row draws
    /// it bare so the mono line keeps its exact current height.
    var filled: Bool = false

    private var style: ReviewBadgeStyle { ReviewBadgeStyle(rawValue: badge) }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(style.tint)
                .frame(width: 6, height: 6)
            if let label = style.label {
                Text(label)
                    .textCase(.uppercase)
            } else if style.isUnknown {
                // Unknown state: the raw wire value is not translatable copy.
                Text(verbatim: style.rawValue)
                    .textCase(.uppercase)
            }
        }
        .font(.hangsMono(10, weight: .semibold))
        .tracking(1.4)
        .foregroundColor(style.tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(filled ? EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8) : EdgeInsets())
        .background {
            if filled {
                Capsule().fill(style.tint.opacity(0.12))
            }
        }
    }
}

/// The question screen's provenance row (#176 Variant A): `model · LANG · badge`
/// in the same 11pt mono caption the `generated_by` model name used alone.
///
/// `isEnabled` is the TestFlight/Debug gate passed in as a plain Bool (the
/// `QuestionRatingEntry.isEnabled` pattern) so a test can force either state
/// without faking a receipt. Disabled renders NOTHING — this row is debug
/// surface, and before #176 the model caption shipped ungated by mistake.
struct QuestionProvenanceRow: View {
    let generatedBy: String?
    let translationLanguage: String?
    let reviewBadge: String?
    let isEnabled: Bool
    let horizontalPadding: CGFloat

    init(question: Question, isEnabled: Bool, horizontalPadding: CGFloat) {
        generatedBy = question.generatedBy
        translationLanguage = question.translationLanguage
        reviewBadge = question.reviewBadge
        self.isEnabled = isEnabled
        self.horizontalPadding = horizontalPadding
    }

    private var hasContent: Bool {
        generatedBy != nil || translationLanguage != nil || reviewBadge != nil
    }

    var body: some View {
        if isEnabled, hasContent {
            HStack(spacing: 8) {
                if let generatedBy {
                    Text(verbatim: generatedBy)
                    separator
                }
                if let translationLanguage {
                    Text(verbatim: translationLanguage.uppercased())
                    if reviewBadge != nil { separator }
                }
                if let reviewBadge {
                    ReviewBadge(badge: reviewBadge)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Theme.Hangs.Colors.ink.opacity(0.45))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            // Dev metadata, not driving copy: kept out of VoiceOver exactly as
            // the model caption was, while staying addressable for tests.
            .accessibilityHidden(true)
            .accessibilityIdentifier("question.reviewBadge")
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundColor(Theme.Hangs.Colors.ink.opacity(0.25))
    }
}

#if DEBUG
    #Preview("Review badges") {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(
                [
                    "approved", "pending_review", "translation_machine",
                    "translation_flagged", "translation_critical",
                    "translation_live", "en_fallback", "brand_new_state",
                ],
                id: \.self
            ) { state in
                HStack(spacing: 12) {
                    ReviewBadge(badge: state)
                    ReviewBadge(badge: state, filled: true)
                }
            }
        }
        .padding()
        .background(Theme.Hangs.Colors.bg)
    }
#endif
