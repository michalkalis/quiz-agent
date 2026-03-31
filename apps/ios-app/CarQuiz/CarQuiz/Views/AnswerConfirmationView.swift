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
    let autoConfirmCountdown: Int
    let autoConfirmEnabled: Bool
    let onConfirm: () -> Void
    let onReRecord: () -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if isProcessing {
                // Processing state
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(Theme.Colors.accentPrimary)
                    .padding()
                    .accessibilityHidden(true)

                Text("Processing...")
                    .font(.displayMD)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .accessibilityLabel("Processing your answer")

                // Cancel button during processing
                if let onCancel = onCancel {
                    Button("Cancel") {
                        onCancel()
                    }
                    .accessibilityLabel("Cancel processing")
                    .accessibilityIdentifier("confirmation.cancel")
                    .buttonStyle(.secondary)
                    .padding(.top, Theme.Spacing.md)
                }
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
                        .accessibilityLabel("Your transcribed answer: \(transcribedAnswer)")
                        .accessibilityIdentifier("confirmation.answer")
                }
                .frame(maxHeight: 200)

                Spacer()

                // Action buttons
                HStack(spacing: Theme.Spacing.md) {
                    // Re-record button
                    Button(action: onReRecord) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "mic.circle.fill")
                                .accessibilityHidden(true)
                            Text("Re-record")
                        }
                    }
                    .accessibilityLabel("Re-record")
                    .accessibilityHint("Record your answer again")
                    .accessibilityIdentifier("confirmation.reRecord")
                    .buttonStyle(.secondary)
                    .disabled(autoConfirmEnabled && autoConfirmCountdown == 0)
                    .opacity(autoConfirmEnabled && autoConfirmCountdown == 0 ? 0.4 : 1.0)

                    // Confirm button with auto-confirm countdown
                    Button(action: onConfirm) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .accessibilityHidden(true)
                            if autoConfirmEnabled && autoConfirmCountdown > 0 {
                                Text("Confirm (\(autoConfirmCountdown)s)")
                            } else {
                                Text("Confirm")
                            }
                        }
                    }
                    .accessibilityLabel(autoConfirmEnabled && autoConfirmCountdown > 0
                        ? "Confirm answer, auto-confirming in \(autoConfirmCountdown) seconds"
                        : "Confirm answer")
                    .accessibilityHint("Submit your transcribed answer")
                    .accessibilityIdentifier("confirmation.confirm")
                    .buttonStyle(.primary)
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Colors.bgPrimary)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }
}

#Preview("Transcription Result") {
    AnswerConfirmationView(
        isProcessing: false,
        transcribedAnswer: "The capital of France is Paris.",
        autoConfirmCountdown: 3,
        autoConfirmEnabled: true,
        onConfirm: {},
        onReRecord: {}
    )
}

#Preview("Processing with Cancel") {
    AnswerConfirmationView(
        isProcessing: true,
        transcribedAnswer: "",
        autoConfirmCountdown: 0,
        autoConfirmEnabled: true,
        onConfirm: {},
        onReRecord: {},
        onCancel: {}
    )
}
