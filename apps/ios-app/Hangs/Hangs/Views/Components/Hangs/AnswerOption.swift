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
    var state: State = .default
    /// Minimum row height. Defaults to 64pt (4-option MCQ); pass 80pt for the 2-option T/F variant.
    var minHeight: CGFloat = 64
    var action: (() -> Void)? = nil

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
        .accessibilityLabel(String(localized: "Option \(key.uppercased()): \(value)", comment: "Accessibility label for a multiple-choice option: letter and answer text"))
        .accessibilityIdentifier("mcq.option.\(key)")
    }

    private var row: some View {
        HStack(spacing: Theme.Hangs.Spacing.md) {
            ZStack {
                Circle().fill(badgeFill)
                Text(key.uppercased())
                    .font(.hangsBody(17, weight: .bold))
                    .foregroundColor(letterColor)
            }
            .frame(width: 40, height: 40)

            Text(value)
                .font(.hangsBody(16, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.leading)

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
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(borderColor, lineWidth: 1.5)
        )
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
        case .selected: return Theme.Hangs.Colors.accentPrimary
        case .correct: return Theme.Hangs.Colors.greenCheck
        case .incorrect: return Theme.Hangs.Colors.pink
        }
    }

    var badgeFill: Color {
        switch self {
        case .default: return Theme.Hangs.Colors.accentPrimarySoft
        case .selected: return Theme.Hangs.Colors.accentPrimary
        case .correct: return Theme.Hangs.Colors.greenCheck
        case .incorrect: return Theme.Hangs.Colors.pink
        }
    }

    var letterColor: Color {
        switch self {
        case .default: return Theme.Hangs.Colors.accentPrimary
        case .selected, .correct, .incorrect: return .white
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

// MARK: - Answer tile (2×2 grid — #125 Variant A "Answer Grid")

/// Compact half-width tile for the #125 2×2 MCQ grid: badge stacked over the
/// value so four choices fit in the space two full-width rows used to take,
/// giving the stem its 360pt floor back. Shares `AnswerOption.State`'s colour
/// mapping (never a second copy). Keeps the `mcq.option.<key>` a11y id so the
/// existing page objects / voice-match highlight are unaffected.
struct AnswerTile: View {
    let key: String
    let value: String
    var state: AnswerOption.State = .default
    /// SE-class shrinks the tile 88 → 76 and tightens the internal gap.
    var compact: Bool = false
    var action: (() -> Void)? = nil

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
        .accessibilityLabel(String(localized: "Option \(key.uppercased()): \(value)", comment: "Accessibility label for a multiple-choice option: letter and answer text"))
        .accessibilityIdentifier("mcq.option.\(key)")
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            ZStack {
                Circle().fill(state.badgeFill)
                Text(key.uppercased())
                    .font(.hangsBody(15, weight: .bold))
                    .foregroundColor(state.letterColor)
            }
            .frame(width: 32, height: 32)

            Text(value)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: compact ? 76 : 88, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(state.borderColor, lineWidth: 1.5)
        )
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
