//
//  OrderPackSummaryStep.swift
//  Hangs
//
//  Step 2 of the #138 order sheet: what is about to be bought, and the
//  no-cancellation disclosure. This is the last screen with a way back — the
//  "Pay & create pack" tap is the point of no return, because generation starts
//  immediately and costs real money on the first call.
//
//  No price row yet: StoreKit wiring for the pack product is #140, and inventing
//  a number here would be worse than showing none.
//

import SwiftUI

struct OrderPackSummaryStep: View {
    @ObservedObject var viewModel: OrderPackViewModel

    var body: some View {
        VStack(spacing: 20) {
            HangsCard(padding: EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)) {
                VStack(alignment: .leading, spacing: 14) {
                    HangsSectionLabel(text: "Custom pack · 30 questions", color: Theme.Hangs.Colors.accentTeal)

                    Text(verbatim: viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.hangsBody(16))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orderPack.summaryPrompt")

                    HStack(spacing: 8) {
                        Text("Quiz language")
                            .font(.hangsBody(13))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                        Text(verbatim: Language.forCode(viewModel.language)?.nativeName
                            ?? Language.default.nativeName)
                            .font(.hangsBody(13, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.pink)
                    }
                }
            }

            noticeBox

            HangsPrimaryButton(title: "Pay & create pack", icon: "sparkles") {
                Task { await viewModel.submit() }
            }
            .accessibilityIdentifier("orderPack.pay")
        }
    }

    private var noticeBox: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.warning)
            Text("Once you pay, the order can't be cancelled. Pack generation is a premium paid service and starts immediately.")
                .font(.hangsBody(13))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
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
