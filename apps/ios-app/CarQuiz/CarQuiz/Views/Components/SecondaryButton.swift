//
//  SecondaryButton.swift
//  Hangs
//
//  Bordered button with elevated background matching Pencil design
//

import SwiftUI

/// Secondary action button with border and elevated background
/// Usage: SecondaryButton(title: "Settings", icon: "gear") { ... }
struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: Theme.Components.iconSM))
                        .accessibilityHidden(true)
                }

                Text(title)
            }
        }
        .accessibilityLabel(title)
        .buttonStyle(.secondary)
    }
}

#Preview {
    VStack(spacing: 20) {
        SecondaryButton(title: "Settings", icon: "gear") {}
        SecondaryButton(title: "Go Home") {}
    }
    .padding()
}
