//
//  HangsChrome.swift
//  Hangs
//
//  Top/bottom chrome: status-bar placeholder, brand row with `hangs.` logo,
//  nav chip buttons, progress counter, hairline divider.
//

import SwiftUI

// MARK: - Brand logo

/// `trubbo.` brand wordmark — blue mono text + pink dot. Inline-sized.
struct HangsBrandMark: View {
    var size: CGFloat = 17
    var showDot: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            // #194: placeholder wordmark until the logo lands (phase D2).
            Text(verbatim: "trubbo.")
                .font(.hangsMono(size, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.blue)
            if showDot {
                Circle()
                    .fill(Theme.Hangs.Colors.action)
                    .frame(width: size * 0.35, height: size * 0.35)
            }
        }
    }
}

// MARK: - Nav chip button

/// 44pt Liquid Glass nav button (#194 B2: glass is the control layer). Used for gear, close, back.
struct HangsNavChip: View {
    let icon: String
    var cornerRadius: CGFloat = Theme.Hangs.Radius.navRound
    var action: () -> Void

    var body: some View {
        // a11y-id: call-site — the identifier belongs to the screen that places this component
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
    }
}

// MARK: - Top brand row (home / settings / complete)

/// Top row with `hangs.` brand on the left and an optional right accessory.
struct HangsBrandRow<Right: View>: View {
    @ViewBuilder var right: () -> Right

    var body: some View {
        HStack {
            HangsBrandMark()
            Spacer()
            right()
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .padding(.vertical, Theme.Hangs.Spacing.xs)
    }
}

extension HangsBrandRow where Right == EmptyView {
    init() { self.init { EmptyView() } }
}

// MARK: - Progress bar

/// 3pt progress bar — the long-set fallback of `HangsQuizProgressHeader`.
struct HangsProgressBar: View {
    /// 0…1
    let progress: Double
    /// Optional fill override — #122 Variant C flips the bar teal for the
    /// duration of a matched-command glow. `nil` = the standard pink.
    var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Hangs.Colors.mutedBorder)
                Capsule()
                    .fill(tint ?? Theme.Hangs.Colors.action)
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, Theme.Hangs.Spacing.xl)
        .animation(.easeInOut(duration: 0.25), value: tint)
    }
}

// MARK: - Page indicator (onboarding dots)

/// Horizontal dot row for onboarding page indication.
/// Active page renders as a wider pill; inactive pages are narrow circles.
/// Both colors and widths are token-bound and exposed for unit testing.
struct HangsPageIndicator: View {
    let pageCount: Int
    let currentPage: Int
    var activeColor: Color = Theme.Hangs.Colors.accentPrimary
    var inactiveColor: Color = Theme.Hangs.Colors.hairline

    func dotColor(at index: Int) -> Color {
        index == currentPage ? activeColor : inactiveColor
    }

    func dotWidth(at index: Int) -> CGFloat {
        index == currentPage ? 20 : 8
    }

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            ForEach(0 ..< pageCount, id: \.self) { i in
                Capsule()
                    .fill(dotColor(at: i))
                    .frame(width: dotWidth(at: i), height: 8)
            }
        }
    }
}

// MARK: - Hairline divider (legacy API kept for older callsites)

struct HangsDivider: View {
    var color: Color = Theme.Hangs.Colors.hairline
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

// MARK: - Back-compat shims (legacy signatures used by older files)

/// Legacy `HangsStatusBar(leading:trailing:)` shim — renders the new brand row
/// with the `leading` mono text shown when provided instead of `hangs.`, and
/// `trailing` mono text on the right. New code should use `HangsBrandRow`.
struct HangsStatusBar: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Theme.Hangs.Colors.blue
    var trailingDotColor: Color = Theme.Hangs.Colors.action
    var backgroundColor: Color = Theme.Hangs.Colors.bg

    var body: some View {
        HStack {
            Text(leading)
                .font(.hangsMono(13, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(leadingColor)
            Spacer()
            HStack(spacing: 6) {
                Text(trailing)
                    .font(.hangsMono(11, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.muted)
                Circle()
                    .fill(trailingDotColor)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .padding(.vertical, 10)
        .background(backgroundColor)
    }
}

/// Legacy `HangsRecordingBar(liveLabel:timeLabel:)` shim — renders a pink rec
/// indicator + timer. New code should use `HangsQuizProgressHeader(isRecording:)`.
struct HangsRecordingBar: View {
    let liveLabel: String
    let timeLabel: String

    var body: some View {
        HStack {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                Circle()
                    .fill(Theme.Hangs.Colors.action)
                    .frame(width: 8, height: 8)
                Text(liveLabel)
                    .font(.hangsMono(11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.action)
            }
            Spacer()
            Text(timeLabel)
                .font(.hangsMono(13, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.action)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .padding(.vertical, 10)
        .background(Theme.Hangs.Colors.bg)
    }
}

/// Legacy `HangsFooterBar(leading:trailing:)` shim — renders a muted mono footer.
struct HangsFooterBar: View {
    let leading: String
    let trailing: String
    var leadingDotColor: Color = Theme.Hangs.Colors.action

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle().fill(leadingDotColor).frame(width: 5, height: 5)
                Text(leading)
                    .font(.hangsMonoMini)
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(trailing)
                    .font(.hangsMonoMini)
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.muted)
                Circle().fill(Theme.Hangs.Colors.muted).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
    }
}

struct HangsTerminalLabel: View {
    let text: String
    var color: Color = Theme.Hangs.Colors.muted
    var font: Font = .hangsMonoLabel

    var body: some View {
        Text(text).font(font).foregroundColor(color).tracking(1.5)
    }
}

struct HangsSessionDot: View {
    let text: String
    var dotColor: Color = Theme.Hangs.Colors.action
    var textColor: Color = Theme.Hangs.Colors.muted

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            Text(text).font(.hangsMonoLabel).tracking(1.5).foregroundColor(textColor)
        }
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 0) {
            HangsBrandRow {
                HangsNavChip(icon: "gearshape") {}
            }
            HangsProgressBar(progress: 0.3)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
