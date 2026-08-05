//
//  HomePacksSection.swift
//  Hangs
//
//  Home "my packs" entry (issue #141, founder variant B 2026-08-05): up to
//  three custom-pack rows directly on Home — a delivered pack plays on one
//  tap, an in-progress pack shows "Preparing…" so a fresh buyer sees their
//  order exists (founder pick: visible even before the first delivery).
//  Failed/refunded orders never surface here — Home is a play entry, not an
//  order-status surface; MyPacksView owns failure comms. Hidden entirely for
//  signed-out users and empty accounts.
//

import SwiftUI

struct HomePacksSection: View {
    @StateObject private var viewModel: MyPacksViewModel
    /// Play a delivered pack by its packId (same path as MyPacksView).
    let onPlayPack: (String) -> Void

    init(service: PackOrderServiceProtocol, onPlayPack: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: MyPacksViewModel(service: service))
        self.onPlayPack = onPlayPack
    }

    #if DEBUG
        /// Test seam: inject a pre-populated view model so inspector tests can
        /// assert the rendered rows without waiting on the async `.task` load.
        init(viewModel: MyPacksViewModel, onPlayPack: @escaping (String) -> Void) {
            _viewModel = StateObject(wrappedValue: viewModel)
            self.onPlayPack = onPlayPack
        }
    #endif

    /// Orders Home surfaces: playable (delivered with a packId) or still
    /// brewing (non-terminal), newest-first as the service returns them,
    /// capped at three — "Show all" covers the rest.
    static func visibleOrders(_ orders: [OrderSnapshot]) -> [OrderSnapshot] {
        Array(orders.filter { ($0.isDelivered && $0.packId != nil) || !$0.isTerminal }.prefix(3))
    }

    var body: some View {
        let visible = Self.visibleOrders(viewModel.orders)
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                HangsSectionLabel(text: "my packs", color: Theme.Hangs.Colors.pink)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                HangsCard {
                    VStack(spacing: 0) {
                        ForEach(visible) { order in
                            packRow(order)
                            HangsDivider()
                        }
                        showAllRow
                    }
                }
                .padding(.horizontal, 20)
            }
            .accessibilityIdentifier("home.myPacksSection")
        }
        // Invisible anchor keeps the keep-fresh loop alive even while the
        // section itself renders nothing (first load, or an account whose only
        // order is terminal-failed) — the `.task` must live on a view that is
        // always mounted.
        Color.clear
            .frame(height: 0)
            .task { await viewModel.start() }
    }

    private func packRow(_ order: OrderSnapshot) -> some View {
        let playable = order.isDelivered && order.packId != nil
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: order.category ?? order.language.uppercased())
                    .font(.hangsBody(15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                if playable {
                    Text("\(order.targetCount) questions")
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                } else {
                    Text("Preparing…")
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.accentPrimary)
                }
            }
            Spacer()
            if playable, let packId = order.packId {
                Button {
                    onPlayPack(packId)
                } label: {
                    playIcon(active: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Start quiz", comment: "Accessibility label: play this custom pack from Home"))
                .accessibilityIdentifier("home.myPacks.play")
            } else {
                playIcon(active: false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func playIcon(active: Bool) -> some View {
        Image(systemName: "play.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(active ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.mutedFaint)
            .frame(width: 34, height: 34)
            .background(
                Circle().fill(active ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.hairline)
            )
            .accessibilityHidden(!active)
    }

    private var showAllRow: some View {
        NavigationLink(value: AppRoute.myPacks) {
            HStack(spacing: 4) {
                Text("Show all")
                    .font(.hangsBody(13, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(Theme.Hangs.Colors.pinkText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.myPacks.showAll")
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            ScrollView {
                HomePacksSection(service: MockPackOrderService(), onPlayPack: { _ in })
            }
            .background(Theme.Hangs.Colors.bg)
        }
    }
#endif
