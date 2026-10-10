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
            PackPreviewCard(topic: viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
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
            .padding(.leading, Theme.Hangs.Spacing.md)
            HangsCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                    TextField(
                        "E.g. space for kids, tough questions on Slovak history, 90s music…",
                        text: $viewModel.prompt,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 8)
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("orderPack.prompt")

                    if !dictation.partialTranscript.isEmpty {
                        Text(verbatim: dictation.partialTranscript)
                            .font(.hangsCaption)
                            .italic()
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("orderPack.partialTranscript")
                    }

                    Text(verbatim: "\(viewModel.trimmedPromptCount) / \(OrderPackViewModel.maxPromptLength)")
                        .font(.hangsCaption.monospacedDigit())
                        .foregroundStyle(viewModel.isValid ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.error)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text("Tell us what the quiz should be about — topic, difficulty, audience. A few words are enough.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Hangs.Spacing.md)
            if let micHint {
                Text(micHint)
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.Hangs.Spacing.md)
                    .accessibilityIdentifier("orderPack.micHint")
            }
        }
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            if dictation.isDictating {
                Label("Stop", systemImage: "stop.circle.fill")
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.error)
            } else {
                Label("Dictate", systemImage: "mic.fill")
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
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
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Theme.Hangs.Spacing.md)
        }
    }
}

/// #194 C8 (canvas Bg-OrderPack): the pack as it will look — an ink card on
/// top of the deck, printing the topic while it is typed. Decoration only;
/// the text field below is the input.
private struct PackPreviewCard: View {
    let topic: String

    var body: some View {
        let style = Theme.Hangs.Category.style(for: nil)
        ZStack {
            card(style.fill.opacity(0.65))
                .rotationEffect(.degrees(-9))
                .offset(x: -Metrics.card.width / 13)
            card(style.fill.opacity(0.8))
                .rotationEffect(.degrees(6))
                .offset(x: Metrics.card.width / 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Custom pack")
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: Theme.Hangs.Spacing.xxs)
                    Text(verbatim: "\(Metrics.packSize)")
                }
                .font(.hangsMonoMini)
                Spacer(minLength: Theme.Hangs.Spacing.xs)
                Text(verbatim: topic)
                    .font(.hangsLabel)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(style.text)
            .padding(Theme.Hangs.Spacing.sm)
            .frame(width: Metrics.card.width, height: Metrics.card.height, alignment: .topLeading)
            .background(card(style.fill).hangsShadow(Theme.Hangs.Shadow.raised))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Hangs.Spacing.xxs)
        .accessibilityHidden(true)
    }

    private func card(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
            .fill(fill)
            .frame(width: Metrics.card.width, height: Metrics.card.height)
    }

    private enum Metrics {
        static let card = CGSize(width: 132, height: 164)
        /// Questions per custom pack, as in the summary copy ("Custom pack · 30
        /// questions") and `PackOrderService.targetCount`.
        static let packSize = 30
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
