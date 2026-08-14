//
//  QuestionRatingSheet.swift
//  Hangs
//
//  The #155 rating panel: ten score buttons (1–10, higher = better) and an
//  optional justification that can be dictated and then edited as text.
//  TestFlight/Debug only — presented by `questionRatingEntry`.
//

import SwiftUI

struct QuestionRatingSheet: View {
    @ObservedObject var viewModel: QuestionRatingViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let questionText = viewModel.questionText {
                        Text(questionText)
                            .font(.hangsBody(14))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("rating.question")
                    }

                    scoreGrid
                    justificationEditor

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.hangsBody(14))
                            .foregroundColor(Theme.Hangs.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("rating.error")
                    }

                    HangsPrimaryButton(
                        title: viewModel.submitState == .saved ? "Saved" : "Save rating",
                        icon: viewModel.submitState == .saved ? "checkmark" : "star.fill",
                        isLoading: viewModel.isSubmitting
                    ) {
                        Task { await viewModel.submit() }
                    }
                    .disabled(!viewModel.canSubmit)
                    .accessibilityIdentifier("rating.submit")
                }
                .padding(20)
            }
            .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
            .navigationTitle("Rate question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // Release the shared mic before leaving — a tap left
                        // installed would collide with the next quiz recording.
                        Task { await viewModel.stopDictation() }
                        dismiss()
                    }
                    .accessibilityIdentifier("rating.cancel")
                }
            }
            .onChange(of: viewModel.submitState) { _, newState in
                // Brief confirmation, then back to the quiz screen untouched.
                if newState == .saved {
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        dismiss()
                    }
                }
            }
            .onDisappear {
                // Catch-all for every dismissal path (swipe-down, Cancel): never
                // let a mic tap survive the sheet. No-op when not dictating.
                Task { await viewModel.stopDictation() }
            }
        }
    }

    // MARK: - Subviews

    private var scoreGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HangsSectionLabel(text: "your rating", color: Theme.Hangs.Colors.pink)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(QuestionRatingViewModel.scoreRange), id: \.self) { score in
                    scoreButton(score)
                }
            }
            Text("1 = worst · 10 = best")
                .font(.hangsBody(12))
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
    }

    private func scoreButton(_ score: Int) -> some View {
        let selected = viewModel.isSelected(score: score)
        return Button {
            viewModel.select(score: score)
        } label: {
            Text(verbatim: "\(score)")
                .font(.hangsMono(16, weight: .semibold))
                .foregroundColor(selected ? Theme.Hangs.Colors.bg : Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                        .fill(selected ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.bgCard)
                )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isSubmitting)
        .accessibilityIdentifier("rating.score.\(score)")
    }

    private var justificationEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HangsSectionLabel(text: "why? (optional)", color: Theme.Hangs.Colors.blue)
                Spacer()
                if viewModel.voiceAvailable {
                    micButton
                }
            }
            HangsCard(padding: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)) {
                TextEditor(text: $viewModel.justification)
                    .font(.hangsBody(16))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .disabled(viewModel.isSubmitting)
                    .accessibilityIdentifier("rating.justification")
                    .overlay(alignment: .topLeading) {
                        if viewModel.justification.isEmpty {
                            Text("Why this score? Say it or type it.")
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
                    .accessibilityIdentifier("rating.partialTranscript")
            }

            if let hint = micHint {
                Text(hint)
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rating.micHint")
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
        .accessibilityIdentifier("rating.mic")
    }

    /// Explains a disabled/denied mic so the rater isn't left tapping a dead button.
    private var micHint: String? {
        if viewModel.isBlockedByQuizRecording {
            return String(localized: "Finish the quiz recording to dictate your note.", comment: "Rating panel: mic disabled because the quiz is currently recording")
        }
        if viewModel.micState == .denied {
            return String(localized: "Microphone access is off — you can still type. Enable it in Settings to dictate.", comment: "Rating panel: mic disabled because permission was denied")
        }
        if viewModel.didHitDictationCap {
            return String(localized: "Reached the 2-minute dictation limit. Tap Dictate to add more.", comment: "Rating panel: dictation auto-stopped at the 120-second cap")
        }
        return nil
    }
}

#if DEBUG
    #Preview {
        QuestionRatingSheet(
            viewModel: QuestionRatingViewModel(
                questionId: "11111111-1111-1111-1111-111111111111",
                questionText: "Which planet is closest to the Sun?",
                ratingService: MockQuestionRatingService(),
                networkService: MockNetworkService()
            )
        )
    }
#endif
