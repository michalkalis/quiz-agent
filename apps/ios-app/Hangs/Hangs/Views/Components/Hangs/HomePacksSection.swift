//
//  HomePacksSection.swift
//  Hangs
//
//  Home "my packs" entry (issue #141, founder variant B 2026-08-05): up to
//  three custom-pack rows directly on Home — a delivered pack plays on one
//  tap, an in-progress pack shows "Preparing" so a fresh buyer sees their
//  order exists (founder pick: visible even before the first delivery).
//  Failed/refunded orders never surface here — Home is a play entry, not an
//  order-status surface; MyPacksView owns failure comms. The pack cards are
//  hidden for signed-out users and empty accounts; the "Create your own pack"
//  card under them is always there when the presenter wires it.
//

import SwiftUI

struct HomePacksSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var viewModel: MyPacksViewModel
    /// Play a delivered pack by its packId (same path as MyPacksView).
    let onPlayPack: (String) -> Void
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
        createPack: CreatePackEntry? = nil,
        quizStart: QuizStart = .idle,
        onPlayPack: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: MyPacksViewModel(service: service))
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
            onPlayPack: @escaping (String) -> Void
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

    var body: some View {
        let visible = Self.visibleOrders(viewModel.orders)
        if !visible.isEmpty {
            // #194 C1: the packs as small ink cards (custom packs = ink, like
            // their question cards), two per row; one per row at accessibility
            // text so a title never truncates.
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                // At accessibility text the label and "Show all" stack: side by
                // side the link was cut to "Zobraz v…" (no "…" in controls).
                headerLayout {
                    HangsSectionLabel(text: "my packs")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    showAllLink
                }
                .padding(.horizontal, Theme.Hangs.Spacing.xxs)
                LazyVGrid(columns: columns, spacing: Theme.Hangs.Spacing.sm) {
                    ForEach(visible) { order in
                        HomePackCard(
                            order: order,
                            isStarting: quizStart.isInFlight && quizStart.packId == order.packId,
                            isPlayDisabled: quizStart.isInFlight,
                            onPlay: onPlayPack
                        )
                    }
                }
            }
            .accessibilityIdentifier("home.myPacksSection")
        }
        if let createPack {
            HomeCreatePackCard(appConfig: createPack.appConfig, action: createPack.action)
        }
        // Invisible anchor keeps the keep-fresh loop alive even while the
        // section itself renders nothing (first load, or an account whose only
        // order is terminal-failed) — the `.task` must live on a view that is
        // always mounted.
        Color.clear
            .frame(height: 0)
            .task { await viewModel.start() }
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

/// One custom pack on Home: ink card, play control top-right, title and its
/// honest count (#182: playable from the first persisted batch).
private struct HomePackCard: View {
    enum Metrics {
        static let minHeight: CGFloat = 120
        static let playSize: CGFloat = 36
        static let minTapTarget: CGFloat = 44
        static let barHeight: CGFloat = 4
    }

    let order: OrderSnapshot
    let isStarting: Bool
    let isPlayDisabled: Bool
    let onPlay: (String) -> Void

    private var style: Theme.Hangs.Category.Style { Theme.Hangs.Category.style(for: nil) }

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
        if order.isPlayable, let packId = order.packId {
            Button {
                onPlay(packId)
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
