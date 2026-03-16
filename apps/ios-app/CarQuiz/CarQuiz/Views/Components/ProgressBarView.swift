//
//  ProgressBarView.swift
//  CarQuiz
//
//  Progress bar with track and gradient fill
//

import SwiftUI

/// Progress bar showing completion with gradient fill
struct ProgressBarView: View {
    let progress: Double // 0.0 to 1.0
    var title: String = "Question Progress"
    var showPercentage: Bool = true

    var body: some View {
        VStack(spacing: 8) {
            // Label row
            HStack {
                Text(title)
                    .font(.labelSM)
                    .foregroundColor(Theme.Colors.textSecondary)

                Spacer()

                if showPercentage {
                    Text("\(Int(progress * 100))%")
                        .font(.labelSMBold)
                        .foregroundColor(Theme.Colors.accentPrimary)
                }
            }

            // Progress track
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.bgElevated)
                        .frame(height: 8)

                    // Progress fill
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Gradients.primaryAlt())
                        .frame(width: geometry.size.width * CGFloat(min(max(progress, 0), 1)), height: 8)
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(Int(progress * 100)) percent")
    }
}

#Preview {
    VStack(spacing: 30) {
        ProgressBarView(progress: 0.3)
        ProgressBarView(progress: 0.7, title: "Completion")
        ProgressBarView(progress: 1.0, showPercentage: false)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
