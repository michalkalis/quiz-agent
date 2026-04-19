//
//  CategoryBadge.swift
//  Hangs
//
//  Purple-tinted category badge matching Pencil design
//

import SwiftUI

/// Purple-tinted pill badge showing question category/topic
struct CategoryBadge: View {
    let category: String

    var body: some View {
        Text(category.capitalized)
            .font(.labelSM)
            .foregroundColor(Theme.Colors.accentPrimary)
            .padding(.vertical, 6)
            .padding(.horizontal, Theme.Spacing.sm)
            .background(Theme.Colors.accentPrimary.opacity(0.1))
            .cornerRadius(Theme.Radius.sm)
            .accessibilityLabel("Category: \(category.capitalized)")
    }
}

#Preview {
    VStack(spacing: 20) {
        CategoryBadge(category: "history")
        CategoryBadge(category: "Science")
        CategoryBadge(category: "geography")
    }
    .padding()
}
