//
//  LevelBadge.swift
//  Hangs
//
//  Purple gradient pill badge showing current level
//

import SwiftUI

/// Purple gradient pill badge with zap icon for level display
struct LevelBadge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.system(size: Theme.Components.iconSM, weight: .medium))
                .foregroundColor(Color(hex: "#FCD34D")) // Gold

            Text("Level \(level)")
                .font(.labelMDBold)
                .foregroundColor(Theme.Colors.textOnAccent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Theme.Spacing.md)
        .background(Theme.Gradients.level())
        .cornerRadius(Theme.Radius.full)
    }
}

#Preview {
    VStack(spacing: 20) {
        LevelBadge(level: 1)
        LevelBadge(level: 5)
        LevelBadge(level: 10)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
