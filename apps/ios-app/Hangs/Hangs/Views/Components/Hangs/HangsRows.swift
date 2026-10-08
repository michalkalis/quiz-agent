//
//  HangsRows.swift
//  Hangs
//
//  Settings-style rows shared by Settings, Home and the order sheet: a row with
//  a value, a toggle row and a read-only value row.
//

import SwiftUI

// MARK: - Label and value line

/// Title and value side by side while both fit on one line; the value moves
/// under the title when they don't (#188 G9 D8: at large Dynamic Type or with a
/// long translation the value used to break mid-word, "Slovenči / na").
/// `ViewThatFits` measures the one-line width, so the switch follows the real
/// text instead of a fixed type-size threshold.
private struct HangsLabelValueLine<Title: View, Value: View>: View {
    @ViewBuilder let title: Title
    @ViewBuilder let value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                title
                Spacer(minLength: 0)
                value
            }
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                title
                value
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Config row (Language / Difficulty / Categories / settings)

/// The look of a config row without a button, for a `Menu` label (Home and
/// Settings pickers), where the menu itself is the control.
struct HangsConfigRowLabel: View {
    let label: LocalizedStringKey
    let value: String
    /// Optional muted line under the label, for rows whose scope isn't
    /// self-evident (#130: quiz language vs. app language).
    var subtitle: LocalizedStringKey? = nil
    /// The value colour is one role app-wide (#188 G12). Override it only for
    /// a row that is an action (muted chevron) or destructive (error).
    var valueColor: Color = Theme.Hangs.Colors.rowValue
    var showsChevron: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HangsLabelValueLine {
                Text(label)
                    .font(.hangsBody(17, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
            } value: {
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
            if let subtitle {
                Text(subtitle)
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, Theme.Hangs.Spacing.md)
        .contentShape(Rectangle())
    }
}

struct HangsConfigRow: View {
    let label: LocalizedStringKey
    let value: String
    var subtitle: LocalizedStringKey? = nil
    var valueColor: Color = Theme.Hangs.Colors.rowValue
    var showsChevron: Bool = true
    var action: (() -> Void)? = nil

    var body: some View {
        // a11y-id: call-site — the identifier belongs to the screen that places this component
        Button(action: { action?() }) {
            HangsConfigRowLabel(
                label: label,
                value: value,
                subtitle: subtitle,
                valueColor: valueColor,
                showsChevron: showsChevron
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toggle row

/// Toggle row for settings (Voice commands, Speak scores aloud). An optional
/// subtitle renders muted under the label for toggles whose effect isn't
/// self-evident (Call Mode — founder batch 2026-07-12, pen Jjcs5 `arow3`).
struct HangsToggleRow: View {
    let label: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.hangsBody(16, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            // a11y-id: call-site — the identifier belongs to the screen that places this component
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Theme.Hangs.Colors.action)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

// MARK: - Value row

/// Static value row (Version · 1.0.0).
struct HangsValueRow: View {
    let label: LocalizedStringKey
    let value: String
    var valueFont: Font = .hangsMono(14, weight: .medium)

    var body: some View {
        HangsLabelValueLine {
            Text(label)
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
        } value: {
            Text(value)
                .font(valueFont)
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}
