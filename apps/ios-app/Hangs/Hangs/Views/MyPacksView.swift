//
//  MyPacksView.swift
//  Hangs
//
//  Lists the account's custom-pack orders (issue #95), newest-first. A delivered
//  row offers "Start quiz" to play that pack. Listing requires an account bearer;
//  without one the pack-api returns 401 and we show a graceful sign-in empty
//  state instead of crashing.
//

import SwiftUI

struct MyPacksView: View {
    let service: PackOrderServiceProtocol
    /// Play a delivered pack by its packId.
    let onPlayPack: (String) -> Void

    @State private var orders: [OrderSnapshot] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if isLoading {
                    ProgressView()
                        .tint(Theme.Hangs.Colors.pink)
                        .padding(.top, 40)
                } else if orders.isEmpty {
                    emptyState
                } else {
                    ForEach(orders) { order in
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
        .task { await load() }
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
                    Text(verbatim: order.status)
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
            Image(systemName: loadFailed ? "person.crop.circle.badge.questionmark" : "tray")
                .font(.system(size: 32, weight: .regular))
                .foregroundColor(Theme.Hangs.Colors.muted)
            Text(loadFailed
                 ? "Sign in to see your packs"
                 : "No packs yet")
                .font(.hangsBody(16, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Text(loadFailed
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

    // MARK: - Load

    private func load() async {
        isLoading = true
        loadFailed = false
        do {
            orders = try await service.listOrders()
        } catch {
            // 401 / no bearer / offline → graceful empty state, never a crash.
            orders = []
            loadFailed = true
        }
        isLoading = false
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            MyPacksView(service: MockPackOrderService(), onPlayPack: { _ in })
        }
    }
#endif
