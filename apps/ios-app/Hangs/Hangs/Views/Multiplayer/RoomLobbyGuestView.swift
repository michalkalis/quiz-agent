//
//  RoomLobbyGuestView.swift
//  Hangs
//
//  #212: a guest in the room, waiting for the host to start.
//

import SwiftUI

struct RoomLobbyGuestView: View {
    @ObservedObject var viewModel: RoomViewModel
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                    youCard
                    HangsSectionLabel(text: "In the room")
                    FlowChips(players: viewModel.players)
                    RoomGuestRulesCard(
                        revealMode: viewModel.state?.revealMode,
                        thinkingSeconds: viewModel.state?.thinkingSeconds,
                        readsAloud: viewModel.state?.readsAloud
                    )
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                Circle()
                    .fill(Theme.Hangs.Colors.live)
                    .frame(width: Metrics.dot, height: Metrics.dot)
                Text("Waiting for the host to start the game")
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.statusHeight)
            .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("room.lobby.waiting")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
        .sheet(isPresented: $isRenaming) {
            RoomNameSheet(title: "Your name in the game", initialName: viewModel.playerName) { name in
                isRenaming = false
                Task { await viewModel.rename(to: name) }
            }
            .presentationDetents([.height(Metrics.sheetHeight)])
        }
    }

    private var youCard: some View {
        let style = Theme.Hangs.Category.player(viewModel.me?.color)
        return Button {
            isRenaming = true
        } label: {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                Text("You're in")
                    .font(.hangsMonoLabel)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Hangs.Category.chipText)
                    .padding(.horizontal, Theme.Hangs.Spacing.sm)
                    .padding(.vertical, Theme.Hangs.Spacing.xxs)
                    .background(Capsule().fill(Theme.Hangs.Category.chipFill))
                Spacer(minLength: Theme.Hangs.Spacing.xl)
                Text(verbatim: viewModel.playerName)
                    .font(.hangsDisplaySM)
                    .hangsHeadlineFit()
                Text("Tap your name to change it.")
                    .font(.hangsBody)
            }
            .foregroundStyle(style.text)
            .padding(Theme.Hangs.Spacing.xl)
            .frame(maxWidth: .infinity, minHeight: Metrics.cardHeight, alignment: .leading)
            // The card keeps its size; the room list below gets the rest.
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                    .fill(style.fill)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("room.lobby.rename")
    }

    private enum Metrics {
        static let dot: CGFloat = 10
        static let statusHeight: CGFloat = 56
        static let cardHeight: CGFloat = 240
        static let sheetHeight: CGFloat = 300
    }
}

/// The players in the room as wrapping name chips.
private struct FlowChips: View {
    let players: [RoomState.Player]

    var body: some View {
        FlowLayout(spacing: Theme.Hangs.Spacing.xs) {
            ForEach(players) { player in
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    RoomPlayerAvatar(name: player.displayName, color: player.color, size: 28)
                    Text(verbatim: player.displayName)
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                }
                .padding(.vertical, Theme.Hangs.Spacing.xxs)
                .padding(.leading, Theme.Hangs.Spacing.xxs)
                .padding(.trailing, Theme.Hangs.Spacing.sm)
                .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
            }
        }
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * Double(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
