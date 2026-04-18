//
//  HangsButton.swift
//  CarQuiz
//
//  Block-style primary (pink filled) and secondary (blue outlined) buttons.
//  Sharp corners, thick borders — blocky terminal aesthetic.
//

import SwiftUI

/// Primary CTA — pink filled block with black text. Sharp corners, thin shadow.
struct HangsPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var trailingIcon: String? = nil
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .tint(Theme.Hangs.Colors.textOnAccent)
                } else if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title)
                    .font(.hangsButton)
                    .tracking(1.5)
                if let trailingIcon = trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .foregroundColor(Theme.Hangs.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.Hangs.Colors.accent)
            .overlay(
                Rectangle().stroke(Theme.Hangs.Colors.accent, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoading ? "Loading" : title)
        .disabled(isLoading)
    }
}

/// Secondary CTA — blue outlined block with blue text on transparent bg.
struct HangsSecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                }
                Text(title)
                    .font(.hangsButton)
                    .tracking(1.5)
            }
            .foregroundColor(Theme.Hangs.Colors.infoAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.clear)
            .overlay(
                Rectangle().stroke(Theme.Hangs.Colors.infoAccent, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Tertiary/ghost CTA — thin border, neutral color.
struct HangsGhostButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = Theme.Hangs.Colors.textSecondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(1.2)
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .overlay(
                Rectangle().stroke(Theme.Hangs.Colors.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        HangsPrimaryButton(title: "START QUIZ", icon: "play.fill", trailingIcon: "arrow.up.right") {}
        HangsSecondaryButton(title: "SETTINGS", icon: "gearshape.fill") {}
        HangsGhostButton(title: "SKIP", icon: "forward.fill") {}
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
    .preferredColorScheme(.dark)
}
#endif
