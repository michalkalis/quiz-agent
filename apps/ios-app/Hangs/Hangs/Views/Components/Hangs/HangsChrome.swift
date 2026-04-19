//
//  HangsChrome.swift
//  Hangs
//
//  Top/bottom chrome: status-bar placeholder, brand row with `hangs.` logo,
//  nav chip buttons, progress counter, hairline divider.
//

import SwiftUI

// MARK: - Brand logo

/// `hangs.` brand wordmark — blue mono text + pink dot. Inline-sized.
struct HangsBrandMark: View {
    var size: CGFloat = 17
    var showDot: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Text("hangs.")
                .font(.hangsMono(size, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.blue)
            if showDot {
                Circle()
                    .fill(Theme.Hangs.Colors.pink)
                    .frame(width: size * 0.35, height: size * 0.35)
            }
        }
    }
}

// MARK: - Nav chip button

/// Square 36pt white nav button with subtle drop shadow. Used for gear, close, back.
struct HangsNavChip: View {
    let icon: String
    var cornerRadius: CGFloat = Theme.Hangs.Radius.navSquare
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white)
                )
                .hangsShadow(Theme.Hangs.Shadow.navChip)
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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

extension HangsBrandRow where Right == EmptyView {
    init() { self.init { EmptyView() } }
}

// MARK: - In-quiz nav (close + brand + progress counter)

struct HangsQuizNav: View {
    let onClose: () -> Void
    let counterText: String
    var counterAccent: Color = Theme.Hangs.Colors.muted

    var body: some View {
        HStack {
            HStack(spacing: 10) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle().fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close quiz")
                HangsBrandMark(size: 13)
            }
            Spacer()
            Text(counterText)
                .font(.hangsMono(13, weight: .semibold))
                .tracking(2)
                .foregroundColor(counterAccent)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

// MARK: - Progress bar

/// 3pt pink/ink progress bar used under the quiz nav.
struct HangsProgressBar: View {
    /// 0…1
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Hangs.Colors.mutedBorder)
                Capsule()
                    .fill(Theme.Hangs.Colors.pink)
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 24)
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
/// `trailing` mono text on the right. New code should use `HangsBrandRow` /
/// `HangsQuizNav` directly.
struct HangsStatusBar: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Theme.Hangs.Colors.blue
    var trailingDotColor: Color = Theme.Hangs.Colors.pink
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
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(backgroundColor)
    }
}

/// Legacy `HangsRecordingBar(liveLabel:timeLabel:)` shim — renders a pink rec
/// indicator + timer. New code should compose `HangsQuizNav` with a recording counter.
struct HangsRecordingBar: View {
    let liveLabel: String
    let timeLabel: String

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.Hangs.Colors.pink)
                    .frame(width: 8, height: 8)
                Text(liveLabel)
                    .font(.hangsMono(11, weight: .semibold))
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.pink)
            }
            Spacer()
            Text(timeLabel)
                .font(.hangsMono(13, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.pink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.Hangs.Colors.bg)
    }
}

/// Legacy `HangsFooterBar(leading:trailing:)` shim — renders a muted mono footer.
struct HangsFooterBar: View {
    let leading: String
    let trailing: String
    var leadingDotColor: Color = Theme.Hangs.Colors.pink

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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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
    var dotColor: Color = Theme.Hangs.Colors.pink
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
        HangsQuizNav(onClose: {}, counterText: "03 / 10")
        HangsProgressBar(progress: 0.3)
        Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
}
#endif
