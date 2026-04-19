//
//  SettingRow.swift
//  Hangs
//
//  Settings row with icon, label, value, and chevron matching Pencil design
//

import SwiftUI

/// Settings row component for consistent settings UI
/// Usage: SettingRow(icon: "globe", title: "Language", value: "English") { ... }
struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    var value: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: Theme.Components.iconMD))
                .foregroundColor(Theme.Colors.accentPrimary)
                .frame(width: Theme.Components.iconMD)

            // Title and optional subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.labelMD)
                    .foregroundColor(Theme.Colors.textPrimary)

                if let value = value {
                    Text(value)
                        .font(.textXS)
                        .foregroundColor(Theme.Colors.textSecondary)
                }
            }

            Spacer()

            // Custom content (menu, button, etc.)
            content()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: Theme.Components.iconSM))
                .foregroundColor(Theme.Colors.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.lg)
        .background(Theme.Colors.bgElevated)
        .cornerRadius(Theme.Radius.md)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1.5)
        )
    }
}

/// Convenience initializer for simple display (no interactive content)
extension SettingRow where Content == EmptyView {
    init(icon: String, title: String, value: String? = nil) {
        self.icon = icon
        self.title = title
        self.value = value
        self.content = { EmptyView() }
    }
}

#Preview {
    VStack(spacing: 12) {
        SettingRow(icon: "globe", title: "Language", value: "English") {
            Text("EN")
                .foregroundColor(Theme.Colors.textSecondary)
        }

        SettingRow(icon: "number", title: "Questions", value: "10") {
            EmptyView()
        }

        SettingRow(icon: "mic.fill", title: "Microphone")
    }
    .padding()
}
