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
        VStack(spacing: 20) {
            topicGroup
            languageGroup

            HangsPrimaryButton(title: "Continue", trailingIcon: "arrow.right") {
                viewModel.advanceToSummary()
            }
            .disabled(!viewModel.isValid)
            .opacity(viewModel.isValid ? 1 : 0.5)
            .accessibilityIdentifier("orderPack.submit")
        }
    }

    private var topicGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsSectionLabel(text: "Quiz topic", color: Theme.Hangs.Colors.pink)
                .padding(.leading, 4)
            HangsCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "E.g. space for kids, tough questions on Slovak history, 90s music…",
                        text: $viewModel.prompt,
                        axis: .vertical
                    )
                    .lineLimit(3 ... 8)
                    .font(.hangsBody(16))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("orderPack.prompt")

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
                .padding(.leading, 4)
        }
    }

    private var languageGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsCard {
                Menu {
                    ForEach(Language.supportedLanguages) { language in
                        Button(language.nativeName) { viewModel.selectLanguage(language.id) }
                    }
                } label: {
                    HangsConfigRow(
                        label: "Quiz language",
                        value: Language.forCode(viewModel.language)?.nativeName
                            ?? Language.default.nativeName,
                        valueColor: Theme.Hangs.Colors.pink,
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
                .padding(.leading, 4)
        }
    }
}

#if DEBUG
    #Preview {
        OrderPackFormStep(viewModel: OrderPackViewModel(service: MockPackOrderService()))
            .padding(20)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
