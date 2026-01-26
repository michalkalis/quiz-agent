//
//  AnswerConfirmationView.swift
//  CarQuiz
//
//  Modal view for confirming or re-recording voice answers
//

import SwiftUI

struct AnswerConfirmationView: View {
    let isProcessing: Bool
    let transcribedAnswer: String
    let onConfirm: () -> Void
    let onReRecord: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if isProcessing {
                // Processing state
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Theme.Colors.accentPrimary)
                    .padding()

                Text("Processing...")
                    .font(.displayMD)
                    .foregroundColor(Theme.Colors.textSecondary)
            } else {
                // Transcription result state
                Text("Your Answer")
                    .font(.displayLG)
                    .foregroundColor(Theme.Colors.textPrimary)

                ScrollView {
                    Text(transcribedAnswer)
                        .font(.textMD)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(Theme.Spacing.lg)
                        .frame(maxWidth: .infinity)
                        .background(Theme.Colors.bgSecondary)
                        .cornerRadius(Theme.Radius.sm)
                }
                .frame(maxHeight: 200)

                Spacer()

                // Action buttons
                HStack(spacing: Theme.Spacing.md) {
                    // Re-record button
                    Button(action: onReRecord) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "mic.circle.fill")
                            Text("Re-record")
                        }
                    }
                    .buttonStyle(.secondary)

                    // Confirm button
                    Button(action: onConfirm) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm")
                        }
                    }
                    .buttonStyle(.primary)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Colors.bgPrimary)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isProcessing)
    }
}

#Preview {
    AnswerConfirmationView(
        isProcessing: false,
        transcribedAnswer: "The capital of France is Paris.",
        onConfirm: {},
        onReRecord: {}
    )
}
