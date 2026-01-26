//
//  StreakBadge.swift
//  CarQuiz
//
//  Orange gradient pill badge showing current streak
//

import SwiftUI

/// Orange gradient pill badge with flame icon for streak display
struct StreakBadge: View {
    let streak: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: Theme.Components.iconSM, weight: .medium))
                .foregroundColor(Theme.Colors.textOnAccent)

            Text("\(streak) Streak!")
                .font(.system(size: Theme.Typography.sizeSM, weight: .bold))
                .foregroundColor(Theme.Colors.textOnAccent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Theme.Spacing.md)
        .background(Theme.Gradients.streak())
        .cornerRadius(Theme.Radius.full)
    }
}

#Preview {
    VStack(spacing: 20) {
        StreakBadge(streak: 3)
        StreakBadge(streak: 5)
        StreakBadge(streak: 10)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
