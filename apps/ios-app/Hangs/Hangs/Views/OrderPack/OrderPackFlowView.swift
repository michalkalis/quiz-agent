//
//  OrderPackFlowView.swift
//  Hangs
//
//  The whole custom-pack purchase flow as ONE modal sheet (#138). The old
//  Settings → push(form) → push(progress) chain let the system back button
//  land the user on the form again *after* they had ordered — one tap away
//  from paying twice. Here every step is a state of the same sheet, and the
//  only way back to the form is from the payment summary, before submit.
//
//  Dismissing the sheet is not cancelling: the view model keeps polling behind
//  it, so reopening shows live progress (or the finished pack).
//

import SwiftUI

struct OrderPackFlowView: View {
    @ObservedObject var viewModel: OrderPackViewModel
    /// Play the delivered pack by its packId (ContentView.playPack).
    let onPlayPack: (String) -> Void
    /// Close the sheet. Owned by the presenter so quiz-start teardown and the
    /// X button flip exactly the same flag.
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch viewModel.state {
                    case .editing:
                        OrderPackFormStep(viewModel: viewModel)
                    case .confirming:
                        OrderPackSummaryStep(viewModel: viewModel)
                    case .submitting:
                        OrderPackPreparingStep(progress: nil, onDismiss: onClose)
                    case .polling(let snapshot):
                        OrderPackPreparingStep(
                            progress: snapshot?.job.map { Double($0.progress) / 100 },
                            onDismiss: onClose
                        )
                    case .delivered(let snapshot):
                        OrderPackReadyStep(
                            packId: snapshot.packId,
                            onPlayPack: { packId in
                                // Close first: the sheet must not survive the
                                // quiz start it triggers.
                                onClose()
                                onPlayPack(packId)
                            },
                            onClose: onClose
                        )
                    case .failed(let message, let retryable):
                        OrderPackFailedStep(
                            message: message,
                            isRetryable: retryable,
                            onRetry: { Task { await viewModel.retry() } },
                            onClose: onClose
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Back exists ONLY on the payment summary — after submit there
                // is no route back to the form for this order.
                if viewModel.state == .confirming {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            viewModel.backToEdit()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Theme.Hangs.Colors.ink)
                        }
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("orderPack.back")
                    }
                }
                if viewModel.allowsInteractiveDismiss {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.Hangs.Colors.muted)
                        }
                        .accessibilityLabel("Close")
                        .accessibilityIdentifier("orderPack.close")
                    }
                }
            }
        }
        // Only the in-flight purchase blocks the swipe — dismissing mid-payment
        // would leave the user unsure whether they were charged.
        .interactiveDismissDisabled(!viewModel.allowsInteractiveDismiss)
    }

    private var navigationTitle: LocalizedStringKey {
        switch viewModel.state {
        case .editing: return "New pack"
        case .confirming: return "Summary"
        case .submitting, .polling, .delivered: return "Your pack"
        case .failed: return "Something went wrong"
        }
    }
}

#if DEBUG
    #Preview {
        OrderPackFlowView(
            viewModel: OrderPackViewModel(service: MockPackOrderService()),
            onPlayPack: { _ in },
            onClose: {}
        )
    }
#endif
