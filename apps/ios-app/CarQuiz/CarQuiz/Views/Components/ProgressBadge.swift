//
//  ProgressBadge.swift
//  CarQuiz
//
//  Pill badge showing quiz progress matching Pencil design
//

import SwiftUI

/// Compact pill badge showing "Q X/Y" progress
struct ProgressBadge: View {
    let current: Int
    let total: Int

    var body: some View {
        Text("Q \(current)/\(total)")
            .font(.labelMD)
            .foregroundColor(Theme.Colors.textPrimary)
            .padding(.vertical, 4)
            .padding(.horizontal, Theme.Spacing.sm)
            .background(Theme.Colors.bgElevated)
            .cornerRadius(Theme.Radius.full)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.full)
                    .stroke(Theme.Colors.border, lineWidth: 1.5)
            )
    }
}

#Preview {
    VStack(spacing: 20) {
        ProgressBadge(current: 1, total: 10)
        ProgressBadge(current: 5, total: 10)
        ProgressBadge(current: 10, total: 10)
    }
    .padding()
}
