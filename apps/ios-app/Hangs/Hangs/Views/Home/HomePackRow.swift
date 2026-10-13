//
//  HomePackRow.swift
//  Hangs
//
//  A custom pack as a row of Home's "my packs" card (Home redesign, founder
//  pick 2026-10-13, canvas "C"), and the separator between the rows.
//

import SwiftUI

/// The hairline between two rows of the packs card, starting under the text
/// like an iOS list separator.
struct HomePackRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Hangs.Colors.hairline)
            .frame(height: 1)
            .padding(.leading, HomePackRow.Metrics.swatchSize + Theme.Hangs.Spacing.sm)
    }
}

/// One custom pack on Home: its colour swatch (#198.4: the same colour as its
/// question cards), title, honest count (#182: playable from the first
/// persisted batch) and a play chip. A playable row is one tap target.
struct HomePackRow: View {
    enum Metrics {
        static let rowHeight: CGFloat = 64
        static let swatchSize: CGFloat = 40
        static let playSize: CGFloat = 36
        static let minTapTarget: CGFloat = 44
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let order: OrderSnapshot
    /// #200: how much of the pack this phone has played; nil before the first question.
    let progress: PackProgress?
    let isStarting: Bool
    let isPlayDisabled: Bool
    let onPlay: (PackPlay) -> Void

    private var style: Theme.Hangs.Category.Style { Theme.Hangs.Category.style(forPack: order.colorKey) }

    var body: some View {
        if order.isPlayable, let pack = order.packPlay {
            Button {
                onPlay(pack)
            } label: {
                rowContent(showsPlay: true)
            }
            .buttonStyle(.plain)
            .disabled(isPlayDisabled)
            .accessibilityHint(isStarting
                ? String(localized: "Loading", comment: "Accessibility label: the custom pack's quiz is starting")
                : String(localized: "Start quiz", comment: "Accessibility label: play this custom pack from Home"))
            .accessibilityIdentifier("home.myPacks.play")
        } else {
            rowContent(showsPlay: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func rowContent(showsPlay: Bool) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.chip, style: .continuous)
                .fill(style.fill)
                .frame(width: Metrics.swatchSize, height: Metrics.swatchSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs / 2) {
                Text(verbatim: order.displayTitle)
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.tail)
                detailLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsPlay {
                playChip
            }
        }
        .padding(.vertical, Theme.Hangs.Spacing.xs)
        .frame(minHeight: Metrics.rowHeight)
        .contentShape(.rect)
    }

    /// The count, then the pack's language when it has a free-text topic.
    private var detailLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xxs) {
            subtitle
            if order.topic != nil {
                Text(verbatim: "· " + (Language.forCode(order.language)?.nativeName ?? order.language.uppercased()))
                    .lineLimit(1)
                    .accessibilityIdentifier("home.myPacks.language")
            }
        }
        .font(.hangsCaption)
        .foregroundStyle(Theme.Hangs.Colors.muted)
    }

    @ViewBuilder private var subtitle: some View {
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

    /// The play chip, with a spinner in place of the triangle while this
    /// pack's quiz starts: the same feedback Home's Start button gives.
    private var playChip: some View {
        Group {
            if isStarting {
                ProgressView()
                    .tint(Theme.Hangs.Colors.ink)
            } else {
                Image(systemName: "play.fill")
                    .font(.hangsCaption.weight(.semibold))
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Metrics.playSize, height: Metrics.playSize)
        .background(Circle().fill(Theme.Hangs.Colors.bgInset))
    }
}
