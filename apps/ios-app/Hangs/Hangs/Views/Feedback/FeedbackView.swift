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
                    Button("Cancel") { dismiss() }
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
            HangsSectionLabel(text: "your feedback", color: Theme.Hangs.Colors.pink)
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
                            Text("What went well or wrong? Anything confusing while driving?")
                                .font(.hangsBody(16))
                                .foregroundColor(Theme.Hangs.Colors.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    private var whatGetsSentCaption: some View {
        Text("Sent with your note: a screenshot, recent app logs, and device info. No audio in this build.")
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
