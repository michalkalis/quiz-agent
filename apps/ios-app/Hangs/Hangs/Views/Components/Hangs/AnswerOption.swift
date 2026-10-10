//
//  AnswerOption.swift
//  Hangs
//
//  Reusable 4-state multiple-choice answer row for the Pencil redesign.
//  Issue #45 task 45.4. Circular letter badge (A/B/C/D) + answer text +
//  optional right status icon. Full-width, 64pt min height, 16pt corners,
//  1.5pt border. Tokens from Theme.Hangs.Colors (45.1).
//

import SwiftUI

struct AnswerOption: View {
    /// The four visual states a choice can be in.
    enum State {
        case `default` // unselected, awaiting tap/voice
        case selected // chosen by the user, result pending
        case correct // revealed as the right answer
        case incorrect // revealed as a wrong choice
    }

    let key: String
    let value: String
    /// #185 track G: the badge glyph — the server's option label ("1".."4" or
    /// "A".."D"); nil keeps the legacy letter from the key.
    var label: String? = nil
    var state: State = .default
    /// #174: this option's answer is being evaluated — the letter badge becomes a
    /// spinner in place, so the loading state lives in the control that was tapped.
    var isLoading: Bool = false
    /// Minimum row height. Defaults to 64pt (4-option MCQ); pass 80pt for the 2-option T/F variant.
    var minHeight: CGFloat = 64
    var action: (() -> Void)? = nil

    private var badgeText: String { label ?? key.uppercased() }

    // MARK: - State → style mapping

    // Delegates to the shared `State` mapping below, so `AnswerTile` reads the
    // SAME state→color roles without duplicating them.

    var borderColor: Color { state.borderColor }
    var badgeFill: Color { state.badgeFill }
    var letterColor: Color { state.letterColor }

    /// SF Symbol for the right-hand status badge, or nil when no status shows.
    var statusSymbol: String? { state.statusSymbol }

    /// Icon color inside the status badge circle (white on colored fill), or nil when no badge.
    var statusIconColor: Color? { state.statusIconColor }

    // MARK: - Body

    var body: some View {
        Group {
            if let action {
                Button(action: action) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Option \(badgeText): \(value)", comment: "Accessibility label for a multiple-choice option: letter and answer text"))
        .accessibilityIdentifier("mcq.option.\(key)")
    }

    private var row: some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            ZStack {
                Circle().fill(badgeFill)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(letterColor)
                        .accessibilityIdentifier("question.processingIndicator")
                } else {
                    Text(verbatim: badgeText)
                        .font(.hangsBody(AnswerOptionMetrics.letterSize, weight: .bold))
                        .foregroundColor(letterColor)
                }
            }
            .frame(width: AnswerOptionMetrics.badge, height: AnswerOptionMetrics.badge)

            Text(value)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                // #174 C2: this row is the layout long options fall back to, so
                // it must never be the thing that truncates them: the row grows.
                // #188 G9 (D11): at large text the option was still cut ("…")
                // because a scaled, wrapped text reported less height than it
                // needed. Now it wraps at full size and claims its full height,
                // never cut (every option lands here at large text, see
                // `MCQOptionPicker.gridMaxTypeSize`); the options scroll on the
                // question screen when they outgrow it.
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Theme.Hangs.Spacing.sm)

            if let statusSymbol, let iconColor = statusIconColor {
                ZStack {
                    Circle().fill(borderColor)
                    Image(systemName: statusSymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(iconColor)
                }
                .frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.sm)
        // #188 G9: a wrapped option keeps air above and below it inside its
        // border (the 64pt floor used to provide it while text was one line).
        .padding(.vertical, Theme.Hangs.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .answerPlate(state)
    }
}

// MARK: - Shared state → color mapping

/// The single source of truth for how a choice's state maps to its design
/// colours / status symbol. Both `AnswerOption` (full-width row) and
/// `AnswerTile` (2×2 grid, #125) read from here (internal so unit tests can
/// assert the mapping directly).
extension AnswerOption.State {
    var borderColor: Color {
        switch self {
        case .default: return Theme.Hangs.Colors.subtleBorder
        case .selected: return Theme.Hangs.Colors.action
        case .correct: return Theme.Hangs.Colors.greenCheck
        case .incorrect: return Theme.Hangs.Colors.wrong
        }
    }

    var badgeFill: Color {
        switch self {
        // #194 R-MCQ: the letter sits on a page-grey plate; the colour accent
        // is kept for the one main action, so a chosen option turns ink.
        case .default: return Theme.Hangs.Colors.bgInset
        case .selected: return Theme.Hangs.Colors.action
        case .correct: return Theme.Hangs.Colors.greenCheck
        case .incorrect: return Theme.Hangs.Colors.wrong
        }
    }

    var letterColor: Color {
        switch self {
        case .default: return Theme.Hangs.Colors.ink
        case .selected: return Theme.Hangs.Colors.textOnAction
        case .correct, .incorrect: return .white
        }
    }

    var statusSymbol: String? {
        switch self {
        case .correct: return "checkmark"
        case .incorrect: return "xmark"
        case .default, .selected: return nil
        }
    }

    var statusIconColor: Color? {
        switch self {
        case .correct, .incorrect: return .white
        case .default, .selected: return nil
        }
    }
}

private enum AnswerOptionMetrics {
    /// R-MCQ letter plate, as tall as one line of option text.
    static let badge: CGFloat = 28
    static let letterSize: CGFloat = 14
    /// R-MCQ option plate corners.
    static let radius: CGFloat = 20
}

private extension View {
    /// The white option plate with its state outline: a hairline at rest, a
    /// firmer line once the option is chosen or revealed.
    func answerPlate(_ state: AnswerOption.State) -> some View {
        background(
            RoundedRectangle(cornerRadius: AnswerOptionMetrics.radius, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AnswerOptionMetrics.radius, style: .continuous)
                .strokeBorder(state.borderColor, lineWidth: state == .default ? 1 : 2)
        )
    }
}

// MARK: - Answer tile (2×2 grid — #125 Variant A "Answer Grid")

/// Compact half-width tile for the #125 2×2 MCQ grid: badge stacked over the
/// value so four choices fit in the space two full-width rows used to take,
/// giving the stem its 360pt floor back. Shares `AnswerOption.State`'s colour
/// mapping (never a second copy). Keeps the `mcq.option.<key>` a11y id so the
/// existing page objects / voice-match highlight are unaffected.
struct AnswerTile: View {
    let key: String
    let value: String
    /// #185 track G: see `AnswerOption.label`.
    var label: String? = nil
    var state: AnswerOption.State = .default
    /// #174: this tile's answer is being evaluated — the letter badge becomes a
    /// spinner in place, so the loading state lives in the tile that was tapped
    /// (same tile size, same text, same selected styling).
    var isLoading: Bool = false
    /// SE-class shrinks the tile 88 → 76 and tightens the internal gap.
    var compact: Bool = false
    var action: (() -> Void)? = nil

    private var badgeText: String { label ?? key.uppercased() }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { tile }
                    .buttonStyle(.plain)
            } else {
                tile
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Option \(badgeText): \(value)", comment: "Accessibility label for a multiple-choice option: letter and answer text"))
        .accessibilityIdentifier("mcq.option.\(key)")
    }

    private var tile: some View {
        // Founder 2026-08-03: badge INLINE with the text (was stacked above it) —
        // the grid was eating too much of the screen; inline drops the tile
        // floor 88 → 60 without shrinking the tap target below driving-safe.
        HStack(spacing: compact ? 8 : 10) {
            ZStack {
                Circle().fill(state.badgeFill)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(state.letterColor)
                        .accessibilityIdentifier("question.processingIndicator")
                } else {
                    Text(verbatim: badgeText)
                        .font(.hangsBody(AnswerOptionMetrics.letterSize, weight: .bold))
                        .foregroundColor(state.letterColor)
                }
            }
            .frame(width: AnswerOptionMetrics.badge, height: AnswerOptionMetrics.badge)

            Text(value)
                // #194 R-MCQ: a short option in the 2×2 grid reads a step larger.
                .font(.hangsBody(17, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                // Slovak option texts run long; 2 lines truncated real answers
                // mid-word (TF build 53 feedback). The grid row grows instead.
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.sm)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: compact ? 54 : 60, alignment: .leading)
        .answerPlate(state)
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 12) {
            AnswerOption(key: "a", value: "Mars")
            AnswerOption(key: "b", value: "Jupiter", state: .selected)
            AnswerOption(key: "c", value: "Saturn", state: .correct)
            AnswerOption(key: "d", value: "Neptune", state: .incorrect)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
