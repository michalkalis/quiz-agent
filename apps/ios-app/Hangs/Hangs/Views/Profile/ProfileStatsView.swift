//
//  ProfileStatsView.swift
//  Hangs
//
//  #216.3 (founder 2026-10-30): "All stats", pushed from the Profile. The grid
//  of stat cards that used to fill the Profile (#213.4); locked ones show
//  what is missing.
//

import SwiftUI

struct ProfileStatsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var viewModel: ProfileViewModel

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.vertical, Theme.Hangs.Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .navigationTitle("All stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .loading:
            HangsCard(padding: cardPadding) {
                ProgressView()
                    .tint(Theme.Hangs.Colors.muted)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("profile.statsLoading")
        case .failed:
            retryCard
        case .loaded:
            LazyVGrid(columns: columns, spacing: Theme.Hangs.Spacing.xs) {
                ForEach(viewModel.cards) { card in
                    ProfileStatTile(card: card)
                }
            }
        }
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Theme.Hangs.Spacing.xs, alignment: .top), count: count)
    }

    private var retryCard: some View {
        Button {
            viewModel.refresh()
        } label: {
            HangsCard(padding: cardPadding) {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    Text("Couldn't load your stats")
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.actionText)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.statsRetry")
    }

    private var cardPadding: EdgeInsets {
        EdgeInsets(top: Theme.Hangs.Spacing.md, leading: Theme.Hangs.Spacing.md, bottom: Theme.Hangs.Spacing.md, trailing: Theme.Hangs.Spacing.md)
    }
}
