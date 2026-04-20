//
//  HangsBlocks.swift
//  Hangs
//
//  Reusable building blocks: hero header, section label, card wrapper,
//  stat box, config row, result banner, answer row.
//

import SwiftUI

// MARK: - Hero title block

/// Editorial hero: big Anton-style headline + short pink rule + muted sub.
struct HangsHeroBlock: View {
    let title: String
    var subtitle: String? = nil
    var titleFont: Font = .hangsBlock
    var alignment: HorizontalAlignment = .leading
    var underlineWidth: CGFloat = 40
    var textColor: Color = Theme.Hangs.Colors.ink

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            Text(title)
                .font(titleFont)
                .tracking(-2)
                .foregroundColor(textColor)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(Theme.Hangs.Colors.pink)
                .frame(width: underlineWidth, height: 2)
            if let subtitle {
                Text(subtitle)
                    .font(.hangsBody(14))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

// MARK: - Section label (pink / blue mono micro-caps)

struct HangsSectionLabel: View {
    let text: String
    var color: Color = Theme.Hangs.Colors.pink

    var body: some View {
        Text(text.uppercased())
            .font(.hangsMono(11, weight: .medium))
            .tracking(2)
            .foregroundColor(color)
    }
}

// MARK: - Card wrapper

/// White rounded card with standard Hangs shadow.
struct HangsCard<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    var cornerRadius: CGFloat = Theme.Hangs.Radius.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white)
            )
            .hangsShadow(Theme.Hangs.Shadow.card)
    }
}

// MARK: - Stat box

/// Card with a mono label and a big condensed number. Used for streak, best, points.
struct HangsStatBox: View {
    let label: String
    let value: String
    var labelColor: Color = Theme.Hangs.Colors.pink
    var valueColor: Color = Theme.Hangs.Colors.blue
    var suffix: String? = nil
    /// When true, renders the number + suffix baseline-aligned on one row.
    var inlineSuffix: Bool = false
    /// Compact layout for dense screens (e.g. result view): smaller padding and value font.
    var compact: Bool = false

    var body: some View {
        let padding = compact
            ? EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
            : EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)
        let inlineValueFont: Font = compact
            ? .hangsDisplay(26, weight: .black)
            : .hangsDisplay(36, weight: .black)
        let stackedValueFont: Font = compact
            ? .hangsDisplay(28, weight: .black)
            : .hangsNumber

        HangsCard(padding: padding) {
            VStack(alignment: .leading, spacing: 4) {
                HangsSectionLabel(text: label, color: labelColor)
                if inlineSuffix, let suffix {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(value)
                            .font(inlineValueFont)
                            .tracking(-1)
                            .foregroundColor(valueColor)
                        Text(suffix)
                            .font(.hangsBody(12, weight: .medium))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                    }
                } else {
                    Text(value)
                        .font(stackedValueFont)
                        .tracking(-1)
                        .foregroundColor(valueColor)
                    if let suffix {
                        Text(suffix)
                            .font(.hangsBody(12, weight: .medium))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                    }
                }
            }
        }
    }
}

// MARK: - Config row (Language / Difficulty / Categories / settings)

struct HangsConfigRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.Hangs.Colors.blue
    var showsChevron: Bool = true
    var action: (() -> Void)? = nil

    var body: some View {
        Button(action: { action?() }) {
            HStack {
                Text(label)
                    .font(.hangsBody(17, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                Spacer()
                HStack(spacing: 6) {
                    Text(value)
                        .font(.hangsBody(17, weight: .semibold))
                        .foregroundColor(valueColor)
                    if showsChevron {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(valueColor)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Toggle row for settings (Voice commands, Speak scores aloud).
struct HangsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.Hangs.Colors.pink)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// Static value row (Version · 1.0.0).
struct HangsValueRow: View {
    let label: String
    let value: String
    var valueFont: Font = .hangsMono(14, weight: .medium)

    var body: some View {
        HStack {
            Text(label)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Spacer()
            Text(value)
                .font(valueFont)
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - Result banner

enum HangsResultKind {
    case correct
    case incorrect

    var label: String { self == .correct ? "CORRECT" : "NOT QUITE" }
    var icon: String { self == .correct ? "checkmark" : "xmark" }
    var color: Color {
        self == .correct ? Theme.Hangs.Colors.greenCorrect : Theme.Hangs.Colors.pink
    }
    var softBg: Color {
        self == .correct ? Theme.Hangs.Colors.greenSoft : Theme.Hangs.Colors.pinkSoft
    }
}

/// Pill with check/x icon + label. Used at the top of the result screens.
struct HangsResultBanner: View {
    let kind: HangsResultKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .bold))
            Text(kind.label)
                .font(.hangsMono(11, weight: .semibold))
                .tracking(2)
        }
        .foregroundColor(kind.color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(kind.softBg)
        )
    }
}

/// Big circular check or x badge inline with a section label (used inside answer cards).
struct HangsInlineBadge: View {
    let kind: HangsResultKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: kind.icon)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(kind.color))
    }
}

// MARK: - Legacy shims

/// Legacy verdict card API — now wraps the new banner + delta text.
struct HangsVerdictCard: View {
    let isCorrect: Bool
    let pointsDelta: String

    var body: some View {
        HangsCard(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
            HStack {
                HangsResultBanner(kind: isCorrect ? .correct : .incorrect)
                Spacer()
                Text(pointsDelta)
                    .font(.hangsDisplay(28, weight: .black))
                    .foregroundColor(isCorrect ? Theme.Hangs.Colors.greenCorrect : Theme.Hangs.Colors.pink)
            }
        }
    }
}

struct HangsAnswerRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.Hangs.Colors.ink

    var body: some View {
        HStack {
            Text(label)
                .font(.hangsMonoLabel)
                .tracking(2)
                .foregroundColor(Theme.Hangs.Colors.muted)
            Spacer()
            Text(value)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: 16) {
            HangsHeroBlock(title: "HANGS", subtitle: "voice-based trivia for the road")
            HStack(spacing: 12) {
                HangsStatBox(label: "streak", value: "47")
                HangsStatBox(label: "best", value: "9.5",
                             labelColor: Theme.Hangs.Colors.blue,
                             valueColor: Theme.Hangs.Colors.pink)
            }
            HangsCard {
                VStack(spacing: 0) {
                    HangsConfigRow(label: "Language", value: "English")
                    Rectangle().fill(Theme.Hangs.Colors.hairline).frame(height: 1)
                    HangsConfigRow(label: "Difficulty", value: "Medium",
                                   valueColor: Theme.Hangs.Colors.pink)
                }
            }
            HangsResultBanner(kind: .correct)
            HangsResultBanner(kind: .incorrect)
        }
        .padding(20)
    }
    .background(Theme.Hangs.Colors.bg)
}
#endif
