//
//  RoomContentSheet.swift
//  Hangs
//
//  #232 (founder 2026-11-14, variant 5A): "What we play" — the categories
//  from Home, or one of the host's custom packs. A pack still being made
//  shows how far it is and cannot be picked yet.
//

import SwiftUI

struct RoomContentSheet: View {
    private enum Metrics {
        static let rowHeight: CGFloat = 56
        static let checkSize: CGFloat = 15
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: RoomViewModel
    @ObservedObject var packs: MyPacksViewModel
    @State private var picked: RoomContent

    init(viewModel: RoomViewModel, packs: MyPacksViewModel) {
        self.viewModel = viewModel
        self.packs = packs
        _picked = State(initialValue: viewModel.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.hangsButton)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .accessibilityIdentifier("room.content.cancel")
                Text("What we play")
                    .font(.hangsHeading)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .frame(maxWidth: .infinity)
                Button("Done", action: done)
                    .font(.hangsButton)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("room.content.done")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                    HangsSectionLabel(text: "Quiz")
                    HangsCard {
                        option(.home, title: Text("Categories from Home"), detail: nil)
                            .accessibilityIdentifier("room.content.home")
                    }
                    if !packRows.isEmpty {
                        HangsSectionLabel(text: "My packs")
                        HangsCard {
                            VStack(spacing: 0) {
                                ForEach(packRows) { order in
                                    if order.id != packRows.first?.id { HangsDivider() }
                                    packOption(order)
                                }
                            }
                        }
                    }
                    Text("Everyone plays the same questions. Only you need the pack.")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(Theme.Hangs.Spacing.md)
        .presentationDetents([.medium, .large])
        .task { await packs.refresh() }
    }

    /// Delivered packs and packs still being made; failed orders stay out.
    private var packRows: [OrderSnapshot] {
        packs.orders.filter { $0.isPlayable || !$0.isTerminal }
    }

    @ViewBuilder private func packOption(_ order: OrderSnapshot) -> some View {
        if order.isFinishedPack, let packId = order.packId {
            option(.pack(id: packId, title: order.displayTitle), title: Text(verbatim: order.displayTitle), detail: nil)
                .accessibilityIdentifier("room.content.pack.\(order.id)")
        } else {
            option(nil, title: Text(verbatim: order.displayTitle), detail: Text("\(order.readyCount) of \(order.targetCount) ready"))
                .accessibilityIdentifier("room.content.pack.\(order.id)")
        }
    }

    /// One choice; `content` nil = not selectable yet.
    private func option(_ content: RoomContent?, title: Text, detail: Text?) -> some View {
        // a11y-id: call-site
        Button {
            if let content { picked = content }
        } label: {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    title
                        .font(.hangsLabel)
                        .foregroundStyle(content == nil ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.ink)
                        .lineLimit(2)
                    if let detail {
                        detail
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if content != nil, content == picked {
                    Image(systemName: "checkmark")
                        .font(.hangsBody(Metrics.checkSize, weight: .semibold))
                        .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(content == nil)
        .accessibilityAddTraits(content != nil && content == picked ? .isSelected : [])
    }

    private func done() {
        let choice = picked
        dismiss()
        Task { await viewModel.play(choice) }
    }
}
