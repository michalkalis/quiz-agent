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
//  MyPacksViewModel (issue #137). #194 C8: card rows with a mini pack deck.
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
            VStack(spacing: Theme.Hangs.Spacing.md) {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(Theme.Hangs.Colors.action)
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
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.lg)
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

    /// #194 C8 (canvas Dec-Now-Packs): each order as a white card with its
    /// pack drawn as a small ink deck (the count on the front card), status
    /// caps, title, and the one action the order allows.
    private func orderRow(_ order: OrderSnapshot) -> some View {
        HangsCard(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16)) {
            HStack(alignment: .top, spacing: Theme.Hangs.Spacing.md) {
                PackMiniDeck(label: deckLabel(order))
                    .opacity(order.isFailure ? 0.4 : 1)

                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text(verbatim: order.statusLabel)
                        .font(.hangsOverline)
                        .textCase(.uppercase)
                        .foregroundStyle(statusColor(order))
                    Text(verbatim: order.category ?? order.language.uppercased())
                        .font(.hangsHeading)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    // #182: a pack is playable from its FIRST persisted batch, so an
                    // order still `in_progress` with a packId plays now and keeps
                    // growing behind the player.
                    if order.isStillGenerating {
                        Text("\(order.readyCount) of \(order.targetCount) questions ready. The rest keeps generating while you play.")
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("myPacks.readyCount")
                        readyBar(order)
                    }

                    actions(order)
                        .padding(.top, Theme.Hangs.Spacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func actions(_ order: OrderSnapshot) -> some View {
        if order.isPlayable, let packId = order.packId {
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

    private func readyBar(_ order: OrderSnapshot) -> some View {
        let fraction = order.targetCount > 0 ? Double(order.readyCount) / Double(order.targetCount) : 0
        return Capsule()
            .fill(Theme.Hangs.Colors.track)
            .frame(height: Metrics.barHeight)
            .overlay(alignment: .leading) {
                // In an overlay, so measuring the bar never feeds its layout.
                GeometryReader { proxy in
                    Capsule()
                        .fill(Theme.Hangs.Colors.accentPrimary)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .padding(.top, Theme.Hangs.Spacing.xxs)
            .accessibilityHidden(true)
    }

    /// The count printed on the front card: what was ordered once it is
    /// ready, what is ready so far while it generates, "!" when it failed.
    private func deckLabel(_ order: OrderSnapshot) -> String {
        if order.isFailure { return "!" }
        if order.isPlayable, !order.isStillGenerating { return "\(order.targetCount)" }
        return "\(order.readyCount)"
    }

    private enum Metrics {
        static let barHeight: CGFloat = 6
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            Image(systemName: viewModel.loadFailed ? "person.crop.circle.badge.questionmark" : "tray")
                .font(.hangsTitle)
                .foregroundStyle(Theme.Hangs.Colors.muted)
            Text(viewModel.loadFailed
                 ? "Sign in to see your packs"
                 : "No packs yet")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.ink)
            Text(viewModel.loadFailed
                 ? "Your ordered packs appear here once you're signed in."
                 : "Create a pack to see it here.")
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func statusColor(_ order: OrderSnapshot) -> Color {
        if order.isDelivered { return Theme.Hangs.Colors.live }
        if order.isFailure { return Theme.Hangs.Colors.error }
        return Theme.Hangs.Colors.blueText
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            MyPacksView(service: MockPackOrderService(), onPlayPack: { _ in })
        }
    }
#endif
