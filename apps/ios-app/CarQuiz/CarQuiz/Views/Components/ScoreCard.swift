//
//  ScoreCard.swift
//  CarQuiz
//
//  Card with gradient border displaying score matching Pencil design
//

import SwiftUI

/// Card showing current score with gradient border
struct ScoreCard: View {
    let score: Double
    var totalQuestions: Int = 10
    var label: String = "Score"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.textSMMedium)
                .foregroundColor(Theme.Colors.textSecondary)

            Text(formattedScore)
                .font(.displayXXLHeavy)
                .foregroundColor(Theme.Colors.textPrimary)
                .lineSpacing(-4)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.bgCard)
        .cornerRadius(Theme.Radius.xl)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .stroke(Theme.Gradients.cardBorder(), lineWidth: 2)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(formattedScore)")
    }

    private var formattedScore: String {
        if score.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(score)) / \(totalQuestions)"
        } else {
            return String(format: "%.1f / %d", score, totalQuestions)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ScoreCard(score: 8.5)
        ScoreCard(score: 10, label: "Final Score")
        ScoreCard(score: 0)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
