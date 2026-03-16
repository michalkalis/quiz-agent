//
//  CountdownTimer.swift
//  CarQuiz
//
//  Warning-colored countdown pill matching Pencil design
//

import SwiftUI

/// Orange/warning-colored countdown pill badge with "Next in" prefix
struct CountdownTimer: View {
    let seconds: Int
    var showPrefix: Bool = true

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "clock.fill")
                .font(.system(size: Theme.Components.iconSM))
                .foregroundColor(Theme.Colors.warning)

            Text(displayText)
                .font(.displayMDBold)
                .foregroundColor(Theme.Colors.warning)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.horizontal, Theme.Spacing.lg)
        .background(Theme.Colors.warningBg)
        .cornerRadius(Theme.Radius.full)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next question in \(seconds) seconds")
    }

    private var displayText: String {
        if showPrefix {
            return "Next in \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        CountdownTimer(seconds: 8)
        CountdownTimer(seconds: 5, showPrefix: false)
        CountdownTimer(seconds: 1)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
