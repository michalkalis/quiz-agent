//
//  HomePacksSection.swift
//  Hangs
//
//  Home "my packs" entry (issue #141, founder variant B 2026-08-05): up to
//  three custom-pack rows directly on Home, in one card with the "Create your
//  own pack" row (Home redesign, founder pick 2026-10-13). A delivered pack plays on one
//  tap, an in-progress pack shows "Preparing" so a fresh buyer sees their
//  order exists (founder pick: visible even before the first delivery).
//  Failed/refunded orders never surface here — Home is a play entry, not an
//  order-status surface; MyPacksView owns failure comms. The "Create your own
//  pack" row closes the card whenever the presenter wires it.
//
//  #200 (TF 2026-10-12: the section "sometimes disappeared"): the title always
//  shows, with what is known under it: loading, no pack yet, the list failed
//  to load (with Retry), or the rows. A row shows how much of the pack this
//  phone has played.
//

import SwiftUI

struct HomePacksSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: MyPacksViewModel
    /// Play a delivered pack (same path as MyPacksView).
    let onPlayPack: (PackPlay) -> Void
    /// The "Create your own pack" card. Nil (inspector tests, previews) hides it.
    let createPack: CreatePackEntry?
    /// The pack whose quiz is starting right now: its play control spins, like
    /// Home's Start button does (TestFlight 2026-10-10: a pack tap gave no
    /// feedback). Any start in flight disables every play control.
    let quizStart: QuizStart

    struct QuizStart: Equatable {
        var isInFlight = false
        var packId: String?

        static let idle = QuizStart()
    }

    struct CreatePackEntry {
        let appConfig: AppConfigStore
        let action: () -> Void
    }

    init(
        service: PackOrderServiceProtocol,
        playedCount: @escaping (String) -> Int = { _ in 0 },
        createPack: CreatePackEntry? = nil,
        quizStart: QuizStart = .idle,
        onPlayPack: @escaping (PackPlay) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: MyPacksViewModel(service: service, playedCount: playedCount))
        self.createPack = createPack
        self.quizStart = quizStart
        self.onPlayPack = onPlayPack
    }

    #if DEBUG
        /// Test seam: inject a pre-populated view model so inspector tests can
        /// assert the rendered rows without waiting on the async `.task` load.
        init(
            viewModel: MyPacksViewModel,
            createPack: CreatePackEntry? = nil,
            quizStart: QuizStart = .idle,
            onPlayPack: @escaping (PackPlay) -> Void
        ) {
            _viewModel = StateObject(wrappedValue: viewModel)
            self.createPack = createPack
            self.quizStart = quizStart
            self.onPlayPack = onPlayPack
        }
    #endif

    /// Orders Home surfaces: playable (delivered with a packId) or still
    /// brewing (non-terminal), newest-first as the service returns them,
    /// capped at three — "Show all" covers the rest.
    static func visibleOrders(_ orders: [OrderSnapshot]) -> [OrderSnapshot] {
        Array(orders.filter { $0.isPlayable || !$0.isTerminal }.prefix(3))
    }

    /// What sits under the section title (#200). A list already loaded wins
    /// over a later failure; an account whose only orders failed shows no
    /// cards, just "Show all" to the list that explains them.
    enum ListState: Equatable {
        case loading
        case failed
        case empty
        case packs([OrderSnapshot])
    }

    static func listState(orders: [OrderSnapshot], isLoading: Bool, loadFailed: Bool) -> ListState {
        if !orders.isEmpty { return .packs(visibleOrders(orders)) }
        if isLoading { return .loading }
        return loadFailed ? .failed : .empty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            // At accessibility text the label and "Show all" stack: side by
            // side the link was cut to "Zobraz v…" (no "…" in controls).
            headerLayout {
                HangsSectionLabel(text: "my packs")
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !viewModel.orders.isEmpty {
                    showAllLink
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.xxs)
            // Home redesign (founder pick 2026-10-13, canvas "C"): the packs
            // and the create entry are rows of one card, like a list.
            if hasStatusOrRows || createPack != nil {
                HangsCard(padding: Metrics.cardPadding) {
                    VStack(spacing: 0) {
                        listContent
                        if let createPack {
                            if hasStatusOrRows {
                                HomePackRowDivider()
                            }
                            HomeCreatePackRow(appConfig: createPack.appConfig, action: createPack.action)
                        }
                    }
                }
            }
        }
        // A container, so the section's id doesn't replace the ids of the
        // rows inside it (UI tests reach each row's play and create control).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.myPacksSection")
        .task { await viewModel.start() }
    }

    private var listState: ListState {
        Self.listState(orders: viewModel.orders, isLoading: viewModel.isLoading, loadFailed: viewModel.loadFailed)
    }

    /// False only for an account whose orders all failed: no row to show.
    private var hasStatusOrRows: Bool {
        if case let .packs(visible) = listState { return !visible.isEmpty }
        return true
    }

    @ViewBuilder private var listContent: some View {
        switch listState {
        case .loading:
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                ProgressView()
                    .tint(Theme.Hangs.Colors.muted)
                Text("Loading your packs…")
            }
            .modifier(SectionStatusLine())
            .accessibilityIdentifier("home.myPacks.loading")
        case .failed:
            Button(action: retryLoad) {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    Text("Couldn't load your packs")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Hangs.Spacing.xxs) {
                        Text("Retry")
                            .font(.hangsLabel)
                        Image(systemName: "arrow.clockwise")
                            .font(.hangsCaption.weight(.bold))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Theme.Hangs.Colors.blue)
                    .fixedSize()
                }
                .modifier(SectionStatusLine())
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.myPacks.retry")
        case .empty:
            Text("No packs yet")
                .modifier(SectionStatusLine())
                .accessibilityIdentifier("home.myPacks.empty")
        case let .packs(visible):
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, order in
                if index > 0 {
                    HomePackRowDivider()
                }
                HomePackRow(
                    order: order,
                    progress: viewModel.progress(of: order),
                    isStarting: quizStart.isInFlight && quizStart.packId == order.packId,
                    isPlayDisabled: quizStart.isInFlight,
                    onPlay: onPlayPack
                )
            }
        }
    }

    private enum Metrics {
        static let cardPadding = EdgeInsets(
            top: Theme.Hangs.Spacing.xxs,
            leading: Theme.Hangs.Spacing.md,
            bottom: Theme.Hangs.Spacing.xxs,
            trailing: Theme.Hangs.Spacing.md
        )
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    private func retryLoad() {
        Task { await viewModel.retryLoad() }
    }

    private var showAllLink: some View {
        NavigationLink(value: AppRoute.myPacks) {
            HStack(spacing: Theme.Hangs.Spacing.xxs) {
                Text("Show all")
                    .font(.hangsLabel)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.hangsCaption.weight(.bold))
                    .accessibilityHidden(true)
            }
            // Home links are blue, like the plan card's.
            .foregroundStyle(Theme.Hangs.Colors.blue)
            .frame(minHeight: HomePackRow.Metrics.minTapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.myPacks.showAll")
    }
}

/// #200: the one-line state under the section title (loading, failed, no
/// pack yet), as a row of the packs card at a full row's height.
private struct SectionStatusLine: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.hangsBody)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .frame(maxWidth: .infinity, minHeight: HomePackRow.Metrics.rowHeight, alignment: .leading)
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
