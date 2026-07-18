//
//  HangsButton.swift
//  Hangs
//
//  Primary / secondary / ghost buttons matching the Pencil redesign.
//  Primary = pink pill with soft shadow; Secondary = white w/ subtle border;
//  Ghost = inline text link.
//

import SwiftUI

/// Primary CTA — pink filled pill. Label + optional leading / trailing SF symbol.
/// #108B: optional Waze-like countdown — bright pink = remaining time draining
/// right→left over a darker base, plus a mono "Ns" chip (pen annotation `sYSN7`).
struct HangsPrimaryButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var trailingIcon: String? = nil
    var isLoading: Bool = false
    var height: CGFloat = 64
    var isDestructive: Bool = false
    /// Seconds left on an active countdown; nil = plain button.
    var countdownSecondsRemaining: Int? = nil
    /// Full countdown duration the fill fraction is computed against.
    var countdownTotal: Int = 0
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCountingDown: Bool {
        (countdownSecondsRemaining ?? 0) > 0 && countdownTotal > 0
    }

    private var countdownFraction: CGFloat {
        guard isCountingDown, let remaining = countdownSecondsRemaining else { return 0 }
        return min(1, max(0, CGFloat(remaining) / CGFloat(max(1, countdownTotal))))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                }
                Text(title)
                    .font(.hangsButton)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 15, weight: .semibold))
                }
                if isCountingDown, let remaining = countdownSecondsRemaining {
                    Text(verbatim: "\(remaining)s")
                        .font(.hangsMono(12, weight: .medium))
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                        )
                        .accessibilityHidden(true)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                ZStack(alignment: .leading) {
                    Capsule().fill(isCountingDown ? Theme.Hangs.Colors.pinkDeep : Theme.Hangs.Colors.pink)
                    if isCountingDown {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Theme.Hangs.Colors.pink)
                                .frame(width: geo.size.width * countdownFraction)
                        }
                        .clipShape(Capsule())
                        .animation(reduceMotion ? nil : .linear(duration: 1), value: countdownFraction)
                    }
                }
            )
            .hangsShadow(isDestructive ? Theme.Hangs.Shadow.ctaStrong : Theme.Hangs.Shadow.cta)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? Text("Loading", comment: "Accessibility label for a button while in its loading state") : Text(title))
        .disabled(isLoading)
    }
}

/// Secondary CTA — card-surface pill with hairline border and ink text + optional icon.
struct HangsSecondaryButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var height: CGFloat = 52
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.hangsBody(16, weight: .semibold))
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                Capsule().fill(Theme.Hangs.Colors.bgCard)
            )
            .overlay(
                Capsule().stroke(Theme.Hangs.Colors.subtleBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Ghost CTA — inline blue text link with optional leading icon. No bg, no border.
struct HangsGhostButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var color: Color = Theme.Hangs.Colors.blue
    var font: Font = .hangsBody(14, weight: .medium)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(font)
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        HangsPrimaryButton(title: "Start Quiz", icon: "play.fill") {}
        HangsPrimaryButton(title: "Next question", trailingIcon: "arrow.right") {}
        HangsPrimaryButton(title: "Confirm", icon: "checkmark", countdownSecondsRemaining: 3, countdownTotal: 10) {}
        HangsSecondaryButton(title: "Home", icon: "house.fill") {}
        HangsGhostButton(title: "Why is this correct?", icon: "book.closed") {}
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
}
#endif
