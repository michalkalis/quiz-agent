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
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.lg) {
                HangsSectionLabel(text: "my packs")
                    .padding(.horizontal, Theme.Hangs.Spacing.lg)
                    .padding(.top, Theme.Hangs.Spacing.xs)
                HangsCard {
                    VStack(spacing: 0) {
                        ForEach(visible) { order in
                            packRow(order)
                            HangsDivider()
                        }
                        showAllRow
                    }
                }
                .padding(.horizontal, Theme.Hangs.Spacing.lg)
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

    private func packRow(_ order: OrderSnapshot) -> some View {
        // #182: playable from the first persisted batch, not only when delivered.
        let playable = order.isPlayable
        return HStack(spacing: Theme.Hangs.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: order.displayTitle)
                    .font(.hangsBody(15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if order.topic != nil {
                    Text(verbatim: Language.forCode(order.language)?.nativeName ?? order.language.uppercased())
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .lineLimit(1)
                        .accessibilityIdentifier("home.myPacks.language")
                }
                if order.isStillGenerating {
                    // Honest count: what can be played right now, out of what
                    // was ordered (#182).
                    Text("\(order.readyCount) of \(order.targetCount) ready")
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.accentPrimary)
                        .accessibilityIdentifier("home.myPacks.readyCount")
                } else if playable {
                    Text("\(order.targetCount) questions")
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                } else {
                    // Same wording as the pack list (#188 G14): one source.
                    Text(verbatim: order.statusLabel)
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.accentPrimary)
                }
            }
            Spacer()
            if playable, let packId = order.packId {
                let isStarting = quizStart.isInFlight && quizStart.packId == packId
                Button {
                    onPlayPack(packId)
                } label: {
                    if isStarting {
                        startingIndicator
                    } else {
                        playIcon(active: true)
                    }
                }
                .buttonStyle(.plain)
                .disabled(quizStart.isInFlight)
                .accessibilityLabel(isStarting
                    ? String(localized: "Loading", comment: "Accessibility label: the custom pack's quiz is starting")
                    : String(localized: "Start quiz", comment: "Accessibility label: play this custom pack from Home"))
                .accessibilityIdentifier("home.myPacks.play")
            } else {
                playIcon(active: false)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
    }

    /// The play chip with a spinner in place of the triangle while this
    /// pack's quiz starts — the same feedback Home's Start button gives.
    private var startingIndicator: some View {
        ProgressView()
            .tint(Theme.Hangs.Category.chipText)
            .frame(width: Metrics.playSize, height: Metrics.playSize)
            .background(Circle().fill(Theme.Hangs.Category.chipFill))
    }

    /// The play chip with a spinner in place of the triangle while this
    /// pack's quiz starts — the same feedback Home's Start button gives.
    private var startingIndicator: some View {
        ProgressView()
            .tint(Theme.Hangs.Colors.textOnAccent)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Theme.Hangs.Colors.pink))
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
            HStack(spacing: Theme.Hangs.Spacing.xxs) {
                Text("Show all")
                    .font(.hangsBody(13, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(Theme.Hangs.Colors.pinkText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Hangs.Spacing.sm)
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
