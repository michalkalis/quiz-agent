//
//  ResultBadge.swift
//  CarQuiz
//
//  Gradient result badge with icon circle matching Pencil design
//

import SwiftUI

/// Badge showing answer result with gradient background and points
struct ResultBadge: View {
    enum ResultType {
        case correct
        case incorrect
        case partiallyCorrect
        case skipped
    }

    let type: ResultType
    var points: Double = 0
    var isMinimal: Bool = false

    var body: some View {
        if isMinimal && (type == .skipped || type == .incorrect) {
            // Minimal style: simple colored text, no background/icon/points
            Text(titleText)
                .font(.displayLG)
                .foregroundColor(Theme.Colors.error)
                .accessibilityLabel(accessibilityResultLabel)
        } else {
            // Full style: gradient card with icon and points
            VStack(spacing: 12) {
                // Icon in frosted circle
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.19)) // #FFFFFF30
                        .frame(
                            width: Theme.Components.resultIconCircle,
                            height: Theme.Components.resultIconCircle
                        )

                    Image(systemName: iconName)
                        .font(.system(size: Theme.Components.resultIcon, weight: .medium))
                        .foregroundColor(Theme.Colors.textOnAccent)
                }

                // Title
                Text(titleText)
                    .font(.system(size: 32, weight: .heavy, design: .default))
                    .foregroundColor(Theme.Colors.textOnAccent)

                // Points
                Text(pointsText)
                    .font(.displayLG)
                    .foregroundColor(Theme.Colors.textOnAccent)
                    .opacity(0.9)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
            .background(backgroundGradient)
            .cornerRadius(Theme.Radius.xl)
            .shadow(
                color: shadowColor,
                radius: 24,
                x: 0,
                y: 8
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityResultLabel)
        }
    }

    // MARK: - Computed Properties

    private var iconName: String {
        switch type {
        case .correct:
            return "checkmark.circle.fill"
        case .incorrect:
            return "xmark.circle.fill"
        case .partiallyCorrect:
            return "exclamationmark.circle.fill"
        case .skipped:
            return "forward.circle.fill"
        }
    }

    private var backgroundGradient: LinearGradient {
        switch type {
        case .correct:
            return Theme.Gradients.correct()
        case .incorrect, .skipped:
            return Theme.Gradients.incorrect()
        case .partiallyCorrect:
            return Theme.Gradients.partial()
        }
    }

    private var shadowColor: Color {
        switch type {
        case .correct:
            return Color(hex: "#22C55E").opacity(0.25)
        case .incorrect, .skipped:
            return Color(hex: "#EF4444").opacity(0.25)
        case .partiallyCorrect:
            return Color(hex: "#F59E0B").opacity(0.25)
        }
    }

    private var titleText: String {
        switch type {
        case .correct:
            return "Correct!"
        case .incorrect:
            return "Incorrect"
        case .partiallyCorrect:
            return "Partial"
        case .skipped:
            return "Skipped"
        }
    }

    private var accessibilityResultLabel: String {
        if points > 0 {
            return "\(titleText), \(String(format: "%.1f", points)) points"
        } else {
            return titleText
        }
    }

    private var pointsText: String {
        if points > 0 {
            return "+\(String(format: "%.1f", points)) pts"
        } else {
            return "+0 pts"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ResultBadge(type: .correct, points: 1.0)
        ResultBadge(type: .incorrect, points: 0, isMinimal: true)
        ResultBadge(type: .partiallyCorrect, points: 0.5)
        ResultBadge(type: .skipped, isMinimal: true)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
