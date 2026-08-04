//
//  MyPacksView.swift
//  Hangs
//
//  Lists the account's custom-pack orders (issue #95), newest-first. A delivered
//  row offers "Start quiz" to play that pack. Listing requires an account bearer;
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
        _viewModel = StateObject(wrappedValue: MyPacksViewModel(service: service))
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
