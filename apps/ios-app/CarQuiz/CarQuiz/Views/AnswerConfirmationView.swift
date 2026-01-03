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
        VStack(spacing: 24) {
            if isProcessing {
                // Processing state
                ProgressView()
                    .scaleEffect(1.5)
                    .padding()

                Text("Processing...")
                    .font(.headline)
                    .foregroundColor(.secondary)
            } else {
                // Transcription result state
                Text("Your Answer")
                    .font(.title2)
                    .fontWeight(.bold)

                ScrollView {
                    Text(transcribedAnswer)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                }
                .frame(maxHeight: 200)

                Spacer()

                // Action buttons
                HStack(spacing: 16) {
                    Button(action: onReRecord) {
                        HStack(spacing: 8) {
                            Image(systemName: "mic.circle.fill")
                            Text("Re-record")
                        }
                        .font(.body)
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button(action: onConfirm) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm")
                        }
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(32)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isProcessing)  // Prevent swipe-to-dismiss while processing
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
