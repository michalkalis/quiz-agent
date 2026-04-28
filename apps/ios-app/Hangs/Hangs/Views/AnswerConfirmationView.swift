//
//  AnswerConfirmationView.swift
//  Hangs
//
//  Modal sheet for confirming or re-recording a voice answer. Editorial
//  Hangs styling: cream bg, pink mono caps label, pink vertical rule + big
//  display typography for the transcript, Hangs pill CTAs, and a pink auto-
//  confirm progress bar mirroring the auto-advance pattern on ResultView.
//

import SwiftUI

struct AnswerConfirmationView: View {
    let isProcessing: Bool
    let transcribedAnswer: String
    let autoConfirmCountdown: Int
    let autoConfirmEnabled: Bool
    let autoConfirmTotal: Int
    let onConfirm: () -> Void
    let onReRecord: () -> Void
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                if isProcessing {
                    processingBody
                } else {
                    transcriptBody
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Theme.Hangs.Colors.bg)
        .interactiveDismissDisabled(true)
    }

    // MARK: - Transcript state

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HangsSectionLabel(text: "YOU SAID", color: Theme.Hangs.Colors.pink)
                .padding(.bottom, 14)

            ScrollView(.vertical, showsIndicators: false) {
                HangsQuestionPrompt(
                    text: transcribedAnswer,
                    barColor: Theme.Hangs.Colors.pink,
                    textFont: .hangsDisplay(32, weight: .black),
                    textColor: Theme.Hangs.Colors.ink,
                    minimumScaleFactor: 0.6
                )
                .accessibilityLabel("Your transcribed answer: \(transcribedAnswer)")
                .accessibilityIdentifier("confirmation.answer")
            }
            .frame(maxHeight: .infinity)

            if autoConfirmEnabled && autoConfirmCountdown > 0 {
                countdownBar
                    .padding(.top, 12)
            }

            HStack(spacing: 10) {
                HangsSecondaryButton(title: "Re-record", icon: "mic.fill", height: 54) {
                    onReRecord()
                }
                .accessibilityIdentifier("confirmation.reRecord")
                .disabled(autoConfirmEnabled && autoConfirmCountdown == 0)
                .opacity(autoConfirmEnabled && autoConfirmCountdown == 0 ? 0.45 : 1)

                HangsPrimaryButton(
                    title: "Confirm",
                    icon: "checkmark",
                    height: 54
                ) {
                    onConfirm()
                }
                .accessibilityLabel(autoConfirmEnabled && autoConfirmCountdown > 0
                    ? "Confirm answer, auto-confirming in \(autoConfirmCountdown) seconds"
                    : "Confirm answer")
                .accessibilityIdentifier("confirmation.confirm")
            }
            .padding(.top, 14)
        }
        .accessibilityIdentifier("confirmation.state.transcript")
    }

    private var countdownBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Auto-confirming in \(autoConfirmCountdown)s")
                    .font(.hangsMono(11, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(Theme.Hangs.Colors.muted)
                Spacer()
            }
            GeometryReader { geo in
                let total = max(1, autoConfirmTotal)
                let fraction = CGFloat(autoConfirmCountdown) / CGFloat(total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Hangs.Colors.mutedBorder)
                    Capsule()
                        .fill(Theme.Hangs.Colors.pink)
                        .frame(width: geo.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 3)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Processing state

    private var processingBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HangsSectionLabel(text: "PROCESSING", color: Theme.Hangs.Colors.blue)

            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Theme.Hangs.Colors.blue)
                    .frame(width: 3, height: 56)
                HStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(Theme.Hangs.Colors.pink)
                        .accessibilityHidden(true)
                    Text("Transcribing…")
                        .font(.hangsDisplay(28, weight: .black))
                        .tracking(-1)
                        .foregroundColor(Theme.Hangs.Colors.ink)
                }
                .accessibilityLabel("Processing your answer")
            }

            Spacer(minLength: 0)

            if let onCancel {
                HangsSecondaryButton(title: "Cancel", icon: "xmark", height: 54) {
                    onCancel()
                }
                .accessibilityLabel("Cancel processing")
                .accessibilityIdentifier("confirmation.cancel")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("confirmation.state.processing")
    }
}

#if DEBUG
#Preview("Transcript") {
    AnswerConfirmationView(
        isProcessing: false,
        transcribedAnswer: "Z mumíí.",
        autoConfirmCountdown: 7,
        autoConfirmEnabled: true,
        autoConfirmTotal: 10,
        onConfirm: {},
        onReRecord: {}
    )
}

#Preview("Transcript long") {
    AnswerConfirmationView(
        isProcessing: false,
        transcribedAnswer: "The capital of France is Paris and it has been so since the 10th century.",
        autoConfirmCountdown: 3,
        autoConfirmEnabled: true,
        autoConfirmTotal: 10,
        onConfirm: {},
        onReRecord: {}
    )
}

#Preview("Processing") {
    AnswerConfirmationView(
        isProcessing: true,
        transcribedAnswer: "",
        autoConfirmCountdown: 0,
        autoConfirmEnabled: true,
        autoConfirmTotal: 10,
        onConfirm: {},
        onReRecord: {},
        onCancel: {}
    )
}
#endif
