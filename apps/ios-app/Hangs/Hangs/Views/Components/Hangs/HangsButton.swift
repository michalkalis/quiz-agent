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
///
/// #188 G9 (D10): a title never ends in "…". At the default text size it stays
/// one line and scales down; once the reader has asked for larger text it may
/// take a second line and the capsule grows to hold it (`height` is a floor).
/// #188 G11: `loadingStyle: .spinnerOnly` for a button that sits under its own
/// status surface (the question screen's listen bar says "Processing…"): the
/// spinner alone, because a second "Processing…" in the button was the pair that
/// truncated to "Spr…". Where the button IS the status (the answer sheet), the
/// default keeps the title beside the spinner.
struct HangsPrimaryButton: View {
    enum LoadingStyle {
        case spinnerAndTitle
        case spinnerOnly
    }

    let title: LocalizedStringKey
    var icon: String? = nil
    var trailingIcon: String? = nil
    var isLoading: Bool = false
    /// Additive to `isLoading`: shows a leading spinner alongside the icon/title
    /// WITHOUT disabling the button — the Home "Cancel start" control (quiz-start
    /// in-button loading) needs to stay tappable while work is in flight, unlike
    /// `isLoading`, which both spins and disables (see `HangsPrimaryButton.isLoading`).
    var showsSpinner: Bool = false
    var loadingStyle: LoadingStyle = .spinnerAndTitle
    /// Minimum height; a two-line title at large text grows past it.
    var height: CGFloat = 64
    /// Seconds left on an active countdown; nil = plain button.
    var countdownSecondsRemaining: Int? = nil
    /// Full countdown duration the fill fraction is computed against.
    var countdownTotal: Int = 0
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The CALLER's `.disabled(…)` — read at this level, so the button's own
    /// `.disabled(isLoading)` below never turns a loading button grey.
    @Environment(\.isEnabled) private var isEnabled

    /// #188 G14 (M9): a disabled button used to be the pink capsule at half
    /// opacity — white on pale pink, near invisible in light mode. Now it is a
    /// neutral fill with muted text, readable in both modes, no CTA shadow.
    private var looksDisabled: Bool { !isEnabled && !isLoading }

    private var isCountingDown: Bool {
        (countdownSecondsRemaining ?? 0) > 0 && countdownTotal > 0
    }

    private static let noShadow = Theme.Hangs.ShadowSpec(color: .clear, radius: 0, y: 0)

    private var fill: Color {
        if looksDisabled { return Theme.Hangs.Colors.mutedBorder }
        return isCountingDown ? Theme.Hangs.Colors.pinkDeep : Theme.Hangs.Colors.pink
    }

    private var countdownFraction: CGFloat {
        guard isCountingDown, let remaining = countdownSecondsRemaining else { return 0 }
        return min(1, max(0, CGFloat(remaining) / CGFloat(max(1, countdownTotal))))
    }

    var body: some View {
        // a11y-id: call-site — the identifier belongs to the screen that places this component
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(Theme.Hangs.Colors.textOnAccent)
                } else {
                    if showsSpinner {
                        ProgressView().tint(Theme.Hangs.Colors.textOnAccent)
                    }
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                if !(isLoading && loadingStyle == .spinnerOnly) {
                    Text(title)
                        .font(.hangsButton)
                        // Localized titles ("Nahrávať") outgrow the EN layout:
                        // scale down first, and at large text wrap rather than
                        // ever cut the word (D10).
                        .hangsButtonTitle(dynamicTypeSize)
                }
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 15, weight: .semibold))
                }
                if isCountingDown, let remaining = countdownSecondsRemaining {
                    Text(verbatim: "\(remaining)s")
                        .font(.hangsMono(12, weight: .medium))
                        .padding(.vertical, 3)
                        .padding(.horizontal, Theme.Hangs.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.22))
                        )
                        // #171 Track C3 safety: in a narrow row the title must
                        // shrink (it already has minimumScaleFactor) and the
                        // seconds must not — a clipped "23s" is the one part of
                        // this button the driver cannot infer from context.
                        .fixedSize()
                        .layoutPriority(1)
                        .accessibilityHidden(true)
                }
            }
            .foregroundColor(looksDisabled ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.textOnAccent)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                ZStack(alignment: .leading) {
                    Capsule().fill(fill)
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
            // A grey capsule casting a pink glow would still read as the CTA.
            .hangsShadow(looksDisabled ? Self.noShadow : Theme.Hangs.Shadow.cta)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? Text("Loading", comment: "Accessibility label for a button while in its loading state") : Text(title))
        .disabled(isLoading)
    }
}

/// Secondary CTA — card-surface pill with hairline border and ink text + optional icon.
/// Same title rule as the primary (D10): one scaled line, two at large text.
struct HangsSecondaryButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    /// Minimum height; a two-line title at large text grows past it.
    var height: CGFloat = 52
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // a11y-id: call-site — the identifier belongs to the screen that places this component
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(title)
                    .font(.hangsBody(16, weight: .semibold))
                    .hangsButtonTitle(dynamicTypeSize)
            }
            .foregroundColor(Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: height)
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
        // a11y-id: call-site — the identifier belongs to the screen that places this component
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

/// #188 G9 (D10): how a button title fits. At the default text size it stays
/// one line and scales down (localized titles outgrow the EN layout), so the
/// bottom rows keep their single strip. At any larger size it wraps instead and
/// the capsule grows: a title scaled to its floor and still too wide was cut to
/// "…" ("Š… 23s", "Spr…"), and scaling a wrapped title made SwiftUI report a
/// smaller size than it drew (the text overflowed the capsule). Pure so the
/// rule is assertable without rendering.
enum HangsButtonTitle {
    static func lineLimit(for size: DynamicTypeSize) -> Int {
        wraps(at: size) ? 3 : 1
    }

    static func wraps(at size: DynamicTypeSize) -> Bool { size > .large }
}

private extension Text {
    func hangsButtonTitle(_ size: DynamicTypeSize) -> some View {
        lineLimit(HangsButtonTitle.lineLimit(for: size))
            .minimumScaleFactor(HangsButtonTitle.wraps(at: size) ? 1 : 0.7)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: HangsButtonTitle.wraps(at: size))
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        HangsPrimaryButton(title: "Start", icon: "play.fill") {}
        HangsPrimaryButton(title: "Next", trailingIcon: "arrow.right") {}
        HangsPrimaryButton(title: "Confirm", icon: "checkmark", countdownSecondsRemaining: 3, countdownTotal: 10) {}
        HangsSecondaryButton(title: "Home", icon: "house.fill") {}
        HangsGhostButton(title: "Why is this correct?", icon: "book.closed") {}
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
}
#endif
