//
//  HangsButton.swift
//  Hangs
//
//  Primary / secondary / ghost buttons.
//  #194 B2: Primary = ink capsule (the one solid action per screen);
//  Secondary = Liquid Glass capsule; Ghost = inline text link.
//

import SwiftUI

/// Primary CTA — ink filled capsule. Label + optional leading / trailing SF symbol.
/// #108B: optional Waze-like countdown — a lighter layer = remaining time
/// draining right→left over the action fill, plus an "Ns" chip.
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
    var height: CGFloat = 56
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

    /// #188 G14 (M9): a disabled button is a neutral fill with muted text,
    /// readable in both modes, no CTA shadow — never the action fill faded.
    private var looksDisabled: Bool { !isEnabled && !isLoading }

    private var isCountingDown: Bool {
        (countdownSecondsRemaining ?? 0) > 0 && countdownTotal > 0
    }

    private static let noShadow = Theme.Hangs.ShadowSpec(color: .clear, radius: 0, y: 0)

    private var fill: Color {
        looksDisabled ? Theme.Hangs.Colors.mutedBorder : Theme.Hangs.Colors.action
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
                    ProgressView().tint(Theme.Hangs.Colors.textOnAction)
                } else {
                    if showsSpinner {
                        ProgressView().tint(Theme.Hangs.Colors.textOnAction)
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
                                .fill(Theme.Hangs.Colors.textOnAction.opacity(0.18))
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
            .foregroundColor(looksDisabled ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.textOnAction)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(
                ZStack(alignment: .leading) {
                    // Lift on the capsule only, never on the title (#194 B2).
                    // A grey capsule with the lift would still read as the CTA.
                    Capsule().fill(fill)
                        .hangsShadow(looksDisabled ? Self.noShadow : Theme.Hangs.Shadow.cta)
                    if isCountingDown {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(Theme.Hangs.Colors.textOnAction.opacity(0.16))
                                .frame(width: geo.size.width * countdownFraction)
                        }
                        .clipShape(Capsule())
                        .animation(reduceMotion ? nil : .linear(duration: 1), value: countdownFraction)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? Text("Loading", comment: "Accessibility label for a button while in its loading state") : Text(title))
        .disabled(isLoading)
    }
}

/// Secondary CTA — Liquid Glass capsule with ink text + optional icon (#194 B2:
/// glass is the control layer; content stays on opaque cards).
/// Same title rule as the primary (D10): one scaled line, two at large text.
struct HangsSecondaryButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    /// Minimum height; a two-line title at large text grows past it.
    var height: CGFloat = 56
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
            .glassEffect(.regular.interactive(), in: Capsule())
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
