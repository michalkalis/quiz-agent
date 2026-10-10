//
//  OrderPackFormStep.swift
//  Hangs
//
//  Step 1 of the #138 order sheet: what the pack should be about. The founder
//  field test showed the old form was unreadable — "ZADANIE" meant nothing, the
//  10-char floor rejected short topics, and Category/Theme confused even the
//  person who commissioned them (dropped here). Language is the real quiz
//  language list now, preselected from Settings instead of a hardcoded triple.
//

import SwiftUI

struct OrderPackFormStep: View {
    @ObservedObject var viewModel: OrderPackViewModel

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            PackPreviewCard(topic: viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            topicGroup
            languageGroup

            HangsPrimaryButton(title: "Continue", trailingIcon: "arrow.right") {
                viewModel.advanceToSummary()
            }
            // #188 G14 (M9): the button draws its own legible disabled state.
            .disabled(!viewModel.isValid)
            .accessibilityIdentifier("orderPack.submit")
        }
    }

    private var topicGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsSectionLabel(text: "Quiz topic")
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
        }
    }

    private var languageGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsCard {
                Menu {
                    ForEach(Language.packOrderLanguages) { language in
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
        OrderPackFormStep(viewModel: OrderPackViewModel(service: MockPackOrderService()))
            .padding(20)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
