//
//  FeedbackView.swift
//  Hangs
//
//  In-app beta feedback sheet (#109, phase 2 — typing only). Presented from the
//  shake gesture (screenshot of the current screen) or the Settings "Send
//  feedback" row (screenshot of Settings). Voice dictation lands in phase 3.
//

import SwiftUI

struct FeedbackView: View {
    @ObservedObject var viewModel: FeedbackViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let screenshot = viewModel.screenshot {
                        screenshotThumbnail(screenshot)
                    }

                    messageEditor

                    whatGetsSentCaption

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.hangsBody(14))
                            .foregroundColor(Theme.Hangs.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("feedback.error")
                    }

                    HangsPrimaryButton(
                        title: viewModel.sendState == .success ? "Sent" : "Send feedback",
                        icon: viewModel.sendState == .success ? "checkmark" : "paperplane.fill",
                        isLoading: viewModel.isSending
                    ) {
                        Task { await viewModel.send() }
                    }
                    .disabled(!viewModel.canSend || viewModel.sendState == .success)
                    .accessibilityIdentifier("feedback.send")
                }
                .padding(20)
            }
            .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
            .navigationTitle("Send feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Release the shared mic before leaving — otherwise the
                        // AudioService tap stays installed after the sheet closes and
                        // the next quiz recording overwrites a still-live engine
                        // (#64/#77 two-engine crash). #109 review.
                        Task { await viewModel.stopDictation() }
                        dismiss()
                    }
                    .accessibilityIdentifier("feedback.cancel")
                }
            }
            .onChange(of: viewModel.sendState) { _, newState in
                // Auto-dismiss shortly after a successful send so the tester lands
                // back on the screen they were reporting about.
                if newState == .success {
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        dismiss()
                    }
                }
            }
            .onDisappear {
                // Catch-all for every dismissal path (swipe-down, interactive
                // dismiss, Cancel): always release the shared mic so no tap survives
                // the sheet. No-op when not dictating. #109 review.
                Task { await viewModel.stopDictation() }
            }
        }
    }

    // MARK: - Subviews

    private func screenshotThumbnail(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HangsSectionLabel(text: "screenshot", color: Theme.Hangs.Colors.blue)
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                            .stroke(Theme.Hangs.Colors.hairline, lineWidth: 1)
                    )

                Button {
                    viewModel.removeScreenshot()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                        .padding(8)
                }
                .accessibilityLabel("Remove screenshot")
                .accessibilityIdentifier("feedback.removeScreenshot")
            }
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HangsSectionLabel(text: "your feedback", color: Theme.Hangs.Colors.pink)
                Spacer()
                if viewModel.voiceAvailable {
                    micButton
                }
            }
            HangsCard(padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)) {
                TextEditor(text: $viewModel.message)
                    .font(.hangsBody(16))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .disabled(viewModel.isSending)
                    .accessibilityIdentifier("feedback.message")
                    .overlay(alignment: .topLeading) {
                        if viewModel.message.isEmpty {
                            Text("What went well or wrong? Say it or type it.")
                                .font(.hangsBody(16))
                                .foregroundColor(Theme.Hangs.Colors.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
            }

            if !viewModel.partialTranscript.isEmpty {
                Text(viewModel.partialTranscript)
                    .font(.hangsBody(14))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feedback.partialTranscript")
            }

            if let hint = micHint {
                Text(hint)
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feedback.micHint")
            }
        }
    }

    @ViewBuilder
    private var micButton: some View {
        Button {
            Task { await viewModel.toggleDictation() }
        } label: {
            if viewModel.isDictating {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.hangsBody(14, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.error)
            } else {
                Label("Dictate", systemImage: "mic.fill")
                    .font(.hangsBody(14, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.blue)
            }
        }
        .disabled(viewModel.micButtonDisabled)
        .opacity(viewModel.micButtonDisabled ? 0.4 : 1)
        .accessibilityIdentifier("feedback.mic")
    }

    /// Explains a disabled/denied mic so the tester isn't left tapping a dead button.
    private var micHint: String? {
        if viewModel.isBlockedByQuizRecording {
            return String(localized: "Finish the quiz recording to dictate feedback.", comment: "Feedback sheet: mic disabled because the quiz is currently recording")
        }
        if viewModel.micState == .denied {
            return String(localized: "Microphone access is off — you can still type. Enable it in Settings to dictate.", comment: "Feedback sheet: mic disabled because permission was denied")
        }
        if viewModel.didHitDictationCap {
            return String(localized: "Reached the 2-minute dictation limit. Tap Dictate to add more.", comment: "Feedback sheet: dictation auto-stopped at the 120-second cap")
        }
        return nil
    }

    private var whatGetsSentCaption: some View {
        Text("Sent with your note: a screenshot, recent app logs, your voice recording, and device info.")
            .font(.hangsBody(13))
            .foregroundColor(Theme.Hangs.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("feedback.whatGetsSent")
    }
}

#if DEBUG
    #Preview {
        FeedbackView(
            viewModel: FeedbackViewModel(
                networkService: MockNetworkService(),
                context: .none,
                screenshot: nil,
                logsProvider: { "sample logs" }
            )
        )
    }
#endif
