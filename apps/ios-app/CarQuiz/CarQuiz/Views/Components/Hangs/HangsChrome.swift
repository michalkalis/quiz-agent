//
//  HangsChrome.swift
//  Hangs
//
//  Terminal-style top/bottom chrome elements for Hangs redesign screens.
//

import SwiftUI

// MARK: - Terminal Label

/// Monospace label with optional leading/trailing slashes ("// HANGS.SYS", "[ QUERY ]").
struct HangsTerminalLabel: View {
    let text: String
    var color: Color = Theme.Hangs.Colors.textSecondary
    var font: Font = .hangsMonoLabel

    var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(color)
            .tracking(0.5)
    }
}

// MARK: - Session Dot

/// Small colored dot with a label — `● LIVE 00:03` or `● REC-IDLE`.
struct HangsSessionDot: View {
    let text: String
    var dotColor: Color = Theme.Hangs.Colors.accent
    var textColor: Color = Theme.Hangs.Colors.textSecondary

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.hangsMonoLabel)
                .foregroundColor(textColor)
                .tracking(0.5)
        }
    }
}

// MARK: - Status Chrome (top bar)

/// Top header bar: `// HANGS.SYS             V2.1.0 • READY`
struct HangsStatusBar: View {
    let leading: String
    let trailing: String
    var leadingColor: Color = Theme.Hangs.Colors.accent
    var trailingDotColor: Color = Theme.Hangs.Colors.success
    var backgroundColor: Color = Theme.Hangs.Colors.bg

    var body: some View {
        HStack {
            HangsTerminalLabel(text: leading, color: leadingColor)
            Spacer()
            HStack(spacing: 8) {
                Text(trailing)
                    .font(.hangsMonoLabel)
                    .foregroundColor(Theme.Hangs.Colors.textSecondary)
                    .tracking(0.5)
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

/// Recording-variant top bar (solid blue strip).
struct HangsRecordingBar: View {
    let liveLabel: String
    let timeLabel: String

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                Text(liveLabel)
                    .font(.hangsMonoLabel)
                    .foregroundColor(.white)
                    .tracking(0.5)
            }
            Spacer()
            Text(timeLabel)
                .font(.hangsMonoLabel)
                .foregroundColor(.white)
                .tracking(0.5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Theme.Hangs.Colors.infoAccent)
    }
}

// MARK: - Footer Bar

/// Bottom footer strip: `• REG.MARK.01                PWR ON • V2.1`
struct HangsFooterBar: View {
    let leading: String
    let trailing: String
    var leadingDotColor: Color = Theme.Hangs.Colors.accent

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(leadingDotColor)
                    .frame(width: 5, height: 5)
                Text(leading)
                    .font(.hangsMonoMini)
                    .foregroundColor(Theme.Hangs.Colors.textTertiary)
                    .tracking(0.5)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(trailing)
                    .font(.hangsMonoMini)
                    .foregroundColor(Theme.Hangs.Colors.textTertiary)
                    .tracking(0.5)
                Circle()
                    .fill(Theme.Hangs.Colors.textTertiary)
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Divider

struct HangsDivider: View {
    var color: Color = Theme.Hangs.Colors.divider
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 0) {
        HangsStatusBar(leading: "// HANGS.SYS", trailing: "V2.1.0 • READY")
        HangsDivider()
        Spacer()
        HangsRecordingBar(liveLabel: "REC.ACTIVE • LIVE", timeLabel: "00:03")
        Spacer()
        HangsFooterBar(leading: "REG.MARK.01", trailing: "PWR ON • V2.1")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
    .preferredColorScheme(.dark)
}
#endif
