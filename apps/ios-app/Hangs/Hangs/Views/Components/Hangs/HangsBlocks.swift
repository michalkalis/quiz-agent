//
//  HangsBlocks.swift
//  Hangs
//
//  Reusable building blocks: hero header, section label, card wrapper,
//  stat box, result banner, answer row. Settings-style rows: HangsRows.swift.
//

import SwiftUI

// MARK: - Hero title block

/// Editorial hero: big Anton-style headline + short pink rule + muted sub.
struct HangsHeroBlock: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
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
                .hangsHeadlineFit()
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

// MARK: - Display headline rule

extension View {
    /// The display (Anton) headline rule: one line, scaled down to fit, never
    /// wrapped mid-word and never cut to "…" (#188 G9 D7). The headline is
    /// already the biggest text on screen, so it stops growing with Dynamic
    /// Type at the largest standard size instead of shrinking back from a
    /// size it could never show. `lines` > 1 only for a headline written with
    /// an explicit line break.
    func hangsHeadlineFit(lines: Int = 1) -> some View {
        lineLimit(lines)
            .minimumScaleFactor(0.4)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

// MARK: - Section label (mono micro-caps)

/// Label above a group of rows. One colour everywhere (#188 G12); pass
/// `color` only when the label itself carries a verdict (correct / wrong).
struct HangsSectionLabel: View {
    let text: LocalizedStringKey
    var color: Color = Theme.Hangs.Colors.sectionLabel

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(.hangsMono(11, weight: .medium))
            .tracking(2)
            .foregroundColor(color)
    }
}

// MARK: - Card wrapper

/// Rounded card on the adaptive `bgCard` surface with standard Hangs shadow.
struct HangsCard<Content: View>: View {
    var padding: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)
    var cornerRadius: CGFloat = Theme.Hangs.Radius.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .hangsShadow(Theme.Hangs.Shadow.card)
    }
}

// MARK: - Stat box

/// Card with a mono label and a big condensed number. Used for streak, best, points.
struct HangsStatBox: View {
    let label: LocalizedStringKey
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
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
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

// MARK: - Result banner

enum HangsResultKind {
    case correct
    case incorrect

    var label: String { self == .correct ? String(localized: "correct", comment: "Result banner label when the answer is correct") : String(localized: "not quite", comment: "Result banner label when the answer is incorrect") }
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
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            Image(systemName: kind.icon)
                .font(.system(size: 11, weight: .bold))
            Text(kind.label)
                .font(.hangsMono(11, weight: .semibold))
                .tracking(2)
        }
        .foregroundColor(kind.color)
        .padding(.horizontal, Theme.Hangs.Spacing.sm)
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
            .foregroundColor(Theme.Hangs.Colors.textOnAccent)
            .frame(width: size, height: size)
            .background(Circle().fill(kind.color))
    }
}

// MARK: - Stat chip

/// Compact inline stat: value + muted label in a hairline capsule.
/// Used where full HangsStatBox is too large (e.g. quiz-complete row).
struct HangsStatChip: View {
    let label: LocalizedStringKey
    let value: String
    var labelColor: Color = Theme.Hangs.Colors.muted
    var valueColor: Color = Theme.Hangs.Colors.ink
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(valueColor)
            }
            Text(value)
                .font(.hangsMono(14, weight: .semibold))
                .foregroundColor(valueColor)
            Text(label)
                .textCase(.uppercase)
                .font(.hangsMono(10, weight: .medium))
                .tracking(1)
                .foregroundColor(labelColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Theme.Hangs.Colors.hairline)
        )
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
    let label: LocalizedStringKey
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
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
        .background(Theme.Hangs.Colors.bgCard)
    }
}

#if DEBUG
    #Preview {
        ScrollView {
            VStack(spacing: 16) {
                HangsHeroBlock(title: "TRUBBO")
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
                        HangsConfigRow(label: "Difficulty", value: "Medium")
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
