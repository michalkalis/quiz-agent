//
//  MyPacksView.swift
//  Hangs
//
//  Lists the account's custom-pack orders (issue #95), newest-first. A delivered
//  row offers "Start quiz" to play that pack; a failed row offers "Try again"
//  (#146), which is the only recovery path once the order flow's own retry has
//  been torn down. Listing requires an account bearer;
//  without one the pack-api returns 401 and we show a graceful sign-in empty
//  state instead of crashing. List state + keep-fresh refresh live in
//  MyPacksViewModel (issue #137).
//

import SwiftUI

struct MyPacksView: View {
    @StateObject private var viewModel: MyPacksViewModel
    /// Play a delivered pack by its packId.
    let onPlayPack: (String) -> Void

    init(service: PackOrderServiceProtocol, onPlayPack: @escaping (String) -> Void) {
        self.init(viewModel: MyPacksViewModel(service: service), onPlayPack: onPlayPack)
    }

    /// Adopt an already-built list model. Used by previews and by the row
    /// structure tests, which need the list in a known loaded state rather than
    /// racing the `.task` that fetches it.
    init(viewModel: MyPacksViewModel, onPlayPack: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onPlayPack = onPlayPack
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(Theme.Hangs.Colors.pink)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if viewModel.orders.isEmpty {
                    emptyState
                } else {
                    ForEach(viewModel.orders) { order in
                        orderRow(order)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .navigationTitle("My packs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.start() }
        .refreshable { await viewModel.refresh() }
        .alert(
            "Couldn't restart the pack",
            isPresented: Binding(
                get: { viewModel.retryErrorMessage != nil },
                set: { if !$0 { viewModel.retryErrorMessage = nil } }
            ),
            presenting: viewModel.retryErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { viewModel.retryErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Rows

    private func orderRow(_ order: OrderSnapshot) -> some View {
        HangsCard(padding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(verbatim: order.category ?? order.language.uppercased())
                        .font(.hangsBody(16, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                    Spacer()
                    Text(verbatim: order.statusLabel)
                        .font(.hangsMono(11, weight: .semibold))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundColor(statusColor(order))
                }

                if order.isDelivered, let packId = order.packId {
                    HangsPrimaryButton(title: "Start quiz", icon: "play.fill", height: 48) {
                        onPlayPack(packId)
                    }
                    .accessibilityIdentifier("myPacks.startQuiz")
                } else if order.isRetryable {
                    // #146: the ONLY in-app way back for a paid order that failed
                    // server-side. The order flow's own "Try again" is gone the
                    // moment the user starts a quiz or relaunches, so without this
                    // row the money is spent and the pack is unrecoverable.
                    // pending/in_progress rows get nothing (the backend 409s a
                    // retry there); refunded gets nothing (nothing left to run).
                    HangsSecondaryButton(title: "Try again", icon: "arrow.clockwise", height: 48) {
                        Task { await viewModel.retry(orderId: order.orderId) }
                    }
                    .accessibilityIdentifier("myPacks.retry")
                    .disabled(viewModel.retryingOrderIds.contains(order.orderId))
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.loadFailed ? "person.crop.circle.badge.questionmark" : "tray")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(Theme.Hangs.Colors.muted)
            Text(viewModel.loadFailed
                 ? "Sign in to see your packs"
                 : "No packs yet")
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Text(viewModel.loadFailed
                 ? "Your ordered packs appear here once you're signed in."
                 : "Create a pack to see it here.")
                .font(.hangsBody(13))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func statusColor(_ order: OrderSnapshot) -> Color {
        if order.isDelivered { return Theme.Hangs.Colors.greenCorrect }
        if order.isFailure { return Theme.Hangs.Colors.error }
        return Theme.Hangs.Colors.blue
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            MyPacksView(service: MockPackOrderService(), onPlayPack: { _ in })
        }
    }
#endif
