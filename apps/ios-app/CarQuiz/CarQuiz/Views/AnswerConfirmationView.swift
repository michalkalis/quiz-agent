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
    var onCancel: (() -> Void)? = nil

    @State private var rerecordCountdown: Int = Config.rerecordWindowDuration
    @State private var countdownTask: Task<Void, Never>?

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

                // Cancel button during processing
                if let onCancel = onCancel {
                    Button("Cancel") {
                        onCancel()
                    }
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
                }
                .frame(maxHeight: 200)

                Spacer()

                // Action buttons
                HStack(spacing: Theme.Spacing.md) {
                    // Re-record button with countdown
                    Button(action: onReRecord) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "mic.circle.fill")
                            if rerecordCountdown > 0 {
                                Text("Re-record (\(rerecordCountdown)s)")
                            } else {
                                Text("Re-record")
                            }
                        }
                    }
                    .buttonStyle(.secondary)
                    .disabled(rerecordCountdown == 0)
                    .opacity(rerecordCountdown == 0 ? 0.4 : 1.0)

                    // Confirm button
                    Button(action: onConfirm) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm")
                        }
                    }
                    .buttonStyle(.primary)
                }
                .onAppear {
                    startRerecordCountdown()
                }
                .onDisappear {
                    countdownTask?.cancel()
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Colors.bgPrimary)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(true)
    }

    private func startRerecordCountdown() {
        rerecordCountdown = Config.rerecordWindowDuration
        countdownTask = Task {
            for remaining in (0..<Config.rerecordWindowDuration).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                rerecordCountdown = remaining
            }
        }
    }
}

#Preview("Transcription Result") {
    AnswerConfirmationView(
        isProcessing: false,
        transcribedAnswer: "The capital of France is Paris.",
        onConfirm: {},
        onReRecord: {}
    )
}

#Preview("Processing with Cancel") {
    AnswerConfirmationView(
        isProcessing: true,
        transcribedAnswer: "",
        onConfirm: {},
        onReRecord: {},
        onCancel: {}
    )
}
