//
//  TrophyIcon.swift
//  Hangs
//
//  Gold gradient trophy icon with glow effect
//

import SwiftUI

/// Large trophy icon with gold gradient and glow for completion screen
struct TrophyIcon: View {
    var size: CGFloat = Theme.Components.trophySize

    var body: some View {
        ZStack {
            // Gold gradient circle
            Circle()
                .fill(Theme.Gradients.gold())
                .frame(width: size, height: size)
                .shadow(
                    color: Color(hex: "#F59E0B").opacity(0.25),
                    radius: 32,
                    x: 0,
                    y: 8
                )
                .shadow(
                    color: Color(hex: "#FCD34D").opacity(0.19),
                    radius: 12,
                    x: 0,
                    y: 0
                )

            // Trophy icon
            Image(systemName: "trophy.fill")
                .font(.system(size: Theme.Components.trophyIconSize, weight: .medium))
                .foregroundColor(Color(hex: "#78350F")) // Dark brown
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        TrophyIcon()
        TrophyIcon(size: 120)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
