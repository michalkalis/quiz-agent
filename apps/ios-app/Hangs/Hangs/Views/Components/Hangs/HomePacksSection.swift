//
//  HomePacksSection.swift
//  Hangs
//
//  Home "my packs" entry (issue #141, founder variant B 2026-08-05): up to
//  three custom-pack rows directly on Home — a delivered pack plays on one
//  tap, an in-progress pack shows "Preparing" so a fresh buyer sees their
//  order exists (founder pick: visible even before the first delivery).
//  Failed/refunded orders never surface here — Home is a play entry, not an
//  order-status surface; MyPacksView owns failure comms. The "Create your own
//  pack" card under them is always there when the presenter wires it.
//
//  #200 (TF 2026-10-12: the section "sometimes disappeared"): the title always
//  shows, with what is known under it: loading, no pack yet, the list failed
//  to load (with Retry), or the cards. A card shows how much of the pack this
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
            listContent
        }
        .accessibilityIdentifier("home.myPacksSection")
        .task { await viewModel.start() }
        if let createPack {
            HomeCreatePackCard(appConfig: createPack.appConfig, action: createPack.action)
        }
    }

    @ViewBuilder private var listContent: some View {
        switch Self.listState(orders: viewModel.orders, isLoading: viewModel.isLoading, loadFailed: viewModel.loadFailed) {
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
                    .foregroundStyle(Theme.Hangs.Colors.actionText)
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
            // #194 C1: the packs as small cards (#198.4: each in its own colour, like
            // their question cards), two per row; one per row at accessibility
            // text so a title never truncates.
            LazyVGrid(columns: columns, spacing: Theme.Hangs.Spacing.sm) {
                ForEach(visible) { order in
                    HomePackCard(
                        order: order,
                        progress: viewModel.progress(of: order),
                        isStarting: quizStart.isInFlight && quizStart.packId == order.packId,
                        isPlayDisabled: quizStart.isInFlight,
                        onPlay: onPlayPack
                    )
                }
            }
        }
    }

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Theme.Hangs.Spacing.sm, alignment: .top), count: count)
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
            .foregroundStyle(Theme.Hangs.Colors.actionText)
            .frame(minHeight: HomePackCard.Metrics.minTapTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.myPacks.showAll")
    }
}

/// #200: the one-line state under the section title (loading, failed, no
/// pack yet), at the label's inset and a full tap target's height.
private struct SectionStatusLine: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.hangsBody)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .frame(maxWidth: .infinity, minHeight: HomePackCard.Metrics.minTapTarget, alignment: .leading)
            .padding(.horizontal, Theme.Hangs.Spacing.xxs)
    }
}

/// One custom pack on Home: a card in the pack's colour, play control top-right, title and its
/// honest count (#182: playable from the first persisted batch).
private struct HomePackCard: View {
    enum Metrics {
        static let minHeight: CGFloat = 120
        static let playSize: CGFloat = 36
        static let minTapTarget: CGFloat = 44
        static let barHeight: CGFloat = 4
    }

    let order: OrderSnapshot
    /// #200: how much of the pack this phone has played; nil before the first question.
    let progress: PackProgress?
    let isStarting: Bool
    let isPlayDisabled: Bool
    let onPlay: (PackPlay) -> Void

    /// #198.4: the pack's own palette colour, the same on its question cards.
    private var style: Theme.Hangs.Category.Style { Theme.Hangs.Category.style(forPack: order.colorKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            playControl
                .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            Text(verbatim: order.displayTitle)
                .font(.hangsLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            if order.topic != nil {
                Text(verbatim: Language.forCode(order.language)?.nativeName ?? order.language.uppercased())
                    .font(.hangsCaption)
                    .foregroundStyle(style.text.opacity(0.72))
                    .lineLimit(1)
                    .accessibilityIdentifier("home.myPacks.language")
            }
            subtitle
            if order.isStillGenerating {
                readyBar
            }
        }
        .foregroundStyle(style.text)
        .padding(EdgeInsets(top: Theme.Hangs.Spacing.sm, leading: Theme.Hangs.Spacing.md, bottom: Theme.Hangs.Spacing.md, trailing: Theme.Hangs.Spacing.sm))
        .frame(maxWidth: .infinity, minHeight: Metrics.minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(style.fill)
        )
    }

    @ViewBuilder private var subtitle: some View {
        Group {
            if order.isStillGenerating {
                // Honest count: what can be played right now, out of what
                // was ordered (#182).
                Text("\(order.readyCount) of \(order.targetCount) ready")
                    .accessibilityIdentifier("home.myPacks.readyCount")
            } else if let progress {
                Text("Played \(progress.played) / \(progress.total)")
                    .accessibilityIdentifier("home.myPacks.progress")
            } else if order.isPlayable {
                Text("\(order.targetCount) questions")
            } else {
                // Same wording as the pack list (#188 G14): one source.
                Text(verbatim: order.statusLabel)
            }
        }
        .font(.hangsCaption)
        .foregroundStyle(style.text.opacity(0.72))
    }

    private var readyBar: some View {
        let fraction = order.targetCount > 0 ? Double(order.readyCount) / Double(order.targetCount) : 0
        return Capsule()
            .fill(style.text.opacity(0.2))
            .frame(height: Metrics.barHeight)
            .overlay(alignment: .leading) {
                // In an overlay, so measuring the bar never feeds its layout.
                GeometryReader { proxy in
                    Capsule()
                        .fill(style.text)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .padding(.top, Theme.Hangs.Spacing.xxs)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var playControl: some View {
        if order.isPlayable, let pack = order.packPlay {
            Button {
                onPlay(pack)
            } label: {
                Group {
                    if isStarting {
                        startingIndicator
                    } else {
                        playIcon(active: true)
                    }
                }
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isPlayDisabled)
            .accessibilityLabel(isStarting
                ? String(localized: "Loading", comment: "Accessibility label: the custom pack's quiz is starting")
                : String(localized: "Start quiz", comment: "Accessibility label: play this custom pack from Home"))
            .accessibilityIdentifier("home.myPacks.play")
        } else {
            playIcon(active: false)
                .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                .accessibilityHidden(true)
        }
    }

    /// The play chip with a spinner in place of the triangle while this
    /// pack's quiz starts — the same feedback Home's Start button gives.
    private var startingIndicator: some View {
        ProgressView()
            .tint(Theme.Hangs.Category.chipText)
            .frame(width: Metrics.playSize, height: Metrics.playSize)
            .background(Circle().fill(Theme.Hangs.Category.chipFill))
    }

    private func playIcon(active: Bool) -> some View {
        Image(systemName: "play.fill")
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(active ? Theme.Hangs.Category.chipText : style.text.opacity(0.5))
            .frame(width: Metrics.playSize, height: Metrics.playSize)
            .background(
                Circle().fill(active ? Theme.Hangs.Category.chipFill : style.text.opacity(0.14))
            )
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
