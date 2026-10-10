//
//  OrderPackSummaryStep.swift
//  Hangs
//
//  Step 2 of the #138 order sheet: what is about to be bought, and the
//  no-cancellation disclosure. This is the last screen with a way back — the
//  "Pay & create pack" tap is the point of no return, because generation starts
//  immediately and costs real money on the first call.
//
//  The price row shows the App Store's localized price for the pack product;
//  when StoreKit can't return it the row is hidden — inventing a number would
//  be worse than showing none.
//

import SwiftUI

struct OrderPackSummaryStep: View {
    @ObservedObject var viewModel: OrderPackViewModel

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            HangsCard(padding: EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)) {
                VStack(alignment: .leading, spacing: 14) {
                    HangsSectionLabel(text: "Custom pack · 30 questions")

                    Text(verbatim: viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.hangsHeading)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orderPack.summaryPrompt")

                    HStack(spacing: Theme.Hangs.Spacing.xs) {
                        Text("Quiz language")
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                        Text(verbatim: Language.forCode(viewModel.language)?.nativeName
                            ?? Language.default.nativeName)
                            .font(.hangsBody.weight(.semibold))
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                    }

                    if let price = viewModel.packPrice {
                        HStack(spacing: Theme.Hangs.Spacing.xs) {
                            Text("Price")
                                .font(.hangsBody)
                                .foregroundStyle(Theme.Hangs.Colors.muted)
                            Text(verbatim: price)
                                .font(.hangsBody.weight(.semibold))
                                .foregroundStyle(Theme.Hangs.Colors.ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("orderPack.price")
                    }
                }
            }

            noticeBox

            HangsPrimaryButton(title: "Pay & create pack", icon: "sparkles") {
                Task { await viewModel.submit() }
            }
            .accessibilityIdentifier("orderPack.pay")
        }
        .task { await viewModel.loadPrice() }
    }

    private var noticeBox: some View {
        HStack(alignment: .top, spacing: Theme.Hangs.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.hangsBody.weight(.semibold))
                .foregroundStyle(Theme.Hangs.Colors.warning)
            Text("Once you pay, the order can't be cancelled. Pack generation is a premium paid service and starts immediately.")
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Hangs.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.warning.opacity(0.12))
        )
        .accessibilityIdentifier("orderPack.noCancelNotice")
    }
}

#if DEBUG
    #Preview {
        let vm = OrderPackViewModel(service: MockPackOrderService())
        vm.prompt = "Space for kids"
        vm.advanceToSummary()
        return OrderPackSummaryStep(viewModel: vm)
            .padding(20)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
