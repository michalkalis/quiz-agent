//
//  OrderPackFormStep.swift
//  Hangs
//
//  Step 1 of the #138 order sheet: what the pack should be about. The founder
//  field test showed the old form was unreadable — "ZADANIE" meant nothing, the
//  10-char floor rejected short topics, and Category/Theme confused even the
//  person who commissioned them (dropped here). Language is the real quiz
//  language list now, preselected from Settings instead of a hardcoded triple.
//  The topic can be dictated (TestFlight feedback 2026-10-09) in the selected
//  pack language, then edited as text.
//

import SwiftUI

struct OrderPackFormStep: View {
    @ObservedObject var viewModel: OrderPackViewModel
    @ObservedObject var dictation: TextDictation

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            topicGroup
            languageGroup

            HangsPrimaryButton(title: "Continue", trailingIcon: "arrow.right", action: continueToSummary)
            // #188 G14 (M9): the button draws its own legible disabled state.
            .disabled(!viewModel.isValid)
            .accessibilityIdentifier("orderPack.submit")
        }
    }

    private var topicGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HangsSectionLabel(text: "Quiz topic")
                Spacer()
                if dictation.isAvailable {
                    micButton
                }
            }
            .padding(.leading, Theme.Hangs.Spacing.xxs)
            HangsCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                    TextField(
                        "E.g. space for kids, tough questions on Slovak history, 90s music…",
                        text: $viewModel.prompt,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 8)
                    .font(.hangsBody(16))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("orderPack.prompt")

                    if !dictation.partialTranscript.isEmpty {
                        Text(verbatim: dictation.partialTranscript)
                            .font(.hangsBody(12))
                            .italic()
                            .foregroundColor(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("orderPack.partialTranscript")
                    }

                    Text(verbatim: "\(viewModel.trimmedPromptCount) / \(OrderPackViewModel.maxPromptLength)")
                        .font(.hangsMono(12, weight: .medium))
                        .foregroundColor(viewModel.isValid ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.pink)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text("Tell us what the quiz should be about — topic, difficulty, audience. A few words are enough.")
                .font(.hangsBody(12))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Hangs.Spacing.xxs)
            if let micHint {
                Text(micHint)
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Hangs.Spacing.xxs)
                    .accessibilityIdentifier("orderPack.micHint")
            }
        }
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            if dictation.isDictating {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.hangsBody(14, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.pink)
            } else {
                Label("Dictate", systemImage: "mic.fill")
                    .font(.hangsBody(14, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.blue)
            }
        }
        .frame(minHeight: Metrics.minTapTarget)
        .disabled(dictation.micButtonDisabled)
        .opacity(dictation.micButtonDisabled ? 0.4 : 1)
        .accessibilityIdentifier("orderPack.mic")
    }

    /// Explains a denied mic or the cap stop so the button never feels dead.
    private var micHint: String? {
        if dictation.micState == .denied {
            return String(localized: "Microphone access is off — you can still type. Enable it in Settings to dictate.", comment: "Order form: mic disabled because permission was denied")
        }
        if dictation.didHitDictationCap {
            return String(localized: "Reached the 2-minute dictation limit. Tap Dictate to add more.", comment: "Order form: dictation auto-stopped at the 120-second cap")
        }
        return nil
    }

    private func toggleDictation() {
        Task {
            // Capture the view model, not this struct: the struct holds
            // `dictation`, which stores the closure — a retain cycle.
            await dictation.toggle(languageCode: viewModel.language) { [viewModel] segment in
                viewModel.prompt = TextDictation.appending(segment, to: viewModel.prompt)
            }
        }
    }

    /// Finish any dictation first so its last words reach the summary.
    private func continueToSummary() {
        Task {
            await dictation.stop()
            viewModel.advanceToSummary()
        }
    }

    private enum Metrics {
        static let minTapTarget: CGFloat = 44
    }

    private var languageGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsCard {
                Menu {
                    ForEach(viewModel.availableLanguages) { language in
                        Button(language.nativeName) { viewModel.selectLanguage(language.id) }
                            .accessibilityIdentifier("orderPack.language.\(language.id)")
                    }
                } label: {
                    HangsConfigRow(
                        label: "Quiz language",
                        value: Language.forCode(viewModel.language)?.nativeName
                            ?? Language.default.nativeName,
                        action: {}
                    )
                    .allowsHitTesting(false)
                }
                .accessibilityIdentifier("orderPack.language")
            }
            Text("Preselected from your quiz language in Settings.")
                .font(.hangsBody(12))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Hangs.Spacing.xxs)
        }
    }
}

#if DEBUG
    #Preview {
        OrderPackFormStep(
            viewModel: OrderPackViewModel(service: MockPackOrderService()),
            dictation: TextDictation(voice: nil, networkService: nil)
        )
            .padding(20)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
