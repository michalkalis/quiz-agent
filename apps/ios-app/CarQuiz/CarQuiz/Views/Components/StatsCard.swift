//
//  StatsCard.swift
//  CarQuiz
//
//  Stats display card with icon, value, and label
//

import SwiftUI

/// Card showing a stat with icon, large value, and label
struct StatsCard: View {
    let icon: String
    let value: String
    let label: String
    var iconColor: Color = Theme.Colors.accentPrimary

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: Theme.Components.iconMD, weight: .medium))
                .foregroundColor(iconColor)

            Text(value)
                .font(.displayXXLHeavy)
                .foregroundColor(Theme.Colors.textPrimary)

            Text(label)
                .font(.textSMMedium)
                .foregroundColor(Theme.Colors.textSecondary)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .background(Theme.Gradients.statsCard())
        .cornerRadius(Theme.Radius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Gradients.cardBorder(), lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

#Preview {
    HStack(spacing: 16) {
        StatsCard(icon: "target", value: "92%", label: "Accuracy")
        StatsCard(icon: "checkmark.circle.fill", value: "8", label: "Correct", iconColor: Theme.Colors.success)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
