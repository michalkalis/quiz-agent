//
//  SettingsView.swift
//  CarQuiz
//
//  Created by Claude Code on 2025-12-30.
//  Settings screen for managing question history and other preferences.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: QuizViewModel
    @State private var showResetConfirmation = false

    var body: some View {
        List {
            Section("Question History") {
                // Show current count with visual warning when nearing capacity
                HStack {
                    Text("Questions Seen")
                    Spacer()
                    Text("\(viewModel.questionHistoryCount) / 500")
                        .foregroundColor(questionCountColor)
                        .fontWeight(viewModel.questionHistoryCount > 400 ? .semibold : .regular)
                }

                // Reset button
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset Question History", systemImage: "trash")
                }
                .disabled(viewModel.questionHistoryCount == 0)
            }

            Section {
                Text("Resetting history allows you to see previously answered questions again.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Reset Question History?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                viewModel.resetQuestionHistory()
            }
        } message: {
            Text("This will allow you to see all questions again. This action cannot be undone.")
        }
    }

    /// Color for question count based on capacity
    private var questionCountColor: Color {
        let count = viewModel.questionHistoryCount

        if count >= 450 {
            return .red  // Critical: Very close to capacity
        } else if count > 400 {
            return .orange  // Warning: Nearing capacity
        } else {
            return .secondary  // Normal
        }
    }
}

// MARK: - Preview
#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            SettingsView(viewModel: .preview)
        }

        NavigationStack {
            SettingsView(viewModel: .previewWithEvaluation)
        }
        .previewDisplayName("With Evaluation")
    }
}
#endif
