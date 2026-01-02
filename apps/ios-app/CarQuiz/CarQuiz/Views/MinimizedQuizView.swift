//
//  MinimizedQuizView.swift
//  CarQuiz
//
//  Compact floating view shown when quiz is minimized
//

import SwiftUI

struct MinimizedQuizView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Status row with question number and score
            HStack(spacing: 16) {
                // Question progress
                HStack(spacing: 6) {
                    Image(systemName: "target")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("Q \(viewModel.questionsAnswered + 1)/\(viewModel.currentSession?.maxQuestions ?? 10)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }

                Spacer()

                // Score
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                    Text("\(Int(viewModel.score))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
            }

            Divider()

            // Expand hint
            HStack(spacing: 6) {
                Text("Tap to expand")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.up.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        .onTapGesture {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                viewModel.isMinimized = false
            }
        }
    }
}

#Preview {
    VStack {
        Spacer()
        MinimizedQuizView(viewModel: QuizViewModel.preview)
            .padding()
    }
    .background(Color.gray.opacity(0.2))
}
