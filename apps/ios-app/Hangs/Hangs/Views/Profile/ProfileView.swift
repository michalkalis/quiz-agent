//
//  ProfileView.swift
//  Hangs
//
//  #213.4 Profile tab (founder 2026-10-28, canvas "Lišta a Profil", Profil 1):
//  the account, the first-recap progress, a grid of stat cards (locked ones
//  show what is missing), My packs, and Settings under the gear. #213.5: the
//  newest recap as a banner on top, played as a full-screen story.
//

import SwiftUI

struct ProfileView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var viewModel: ProfileViewModel
    /// The plan from /usage, nil until it has loaded.
    var isPlus: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xl) {
                header
                NavigationLink(value: AppRoute.settings) {
                    ProfileAccountRow(account: viewModel.account, isPlus: isPlus)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.account")

                if let recap = viewModel.latestRecap {
                    ProfileRecapBanner(recap: recap) { viewModel.play(recap) }
                }

                if let progress = viewModel.firstRecapProgress {
                    ProfileFirstRecapCard(progress: progress)
                }

                statsSection
                packsSection
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.bottom, Theme.Hangs.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        // Also on the way back from Settings: a sign-in there renames the row.
        .onAppear(perform: viewModel.appeared)
        .fullScreenCover(item: $viewModel.playingRecap) { recap in
            RecapStoryView(recap: recap, onShareOpened: { viewModel.shareOpened(recap) }) { seen, total in
                viewModel.storyClosed(recap, slidesSeen: seen, slidesTotal: total)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("PROFILE")
                .font(.hangsTitle)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink(value: AppRoute.settings) {
                Image(systemName: "gearshape")
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .frame(width: 44, height: 44)
                    // Same glass circle as Home's former gear (`HangsNavChip`).
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Settings", comment: "Accessibility label for the settings navigation button"))
            .accessibilityIdentifier("profile.settings")
        }
        .padding(.leading, Theme.Hangs.Spacing.xxs)
        .padding(.top, Theme.Hangs.Spacing.xs)
    }

    // MARK: - Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            sectionLabel("your stats")
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
            default:
                LazyVGrid(columns: columns, spacing: Theme.Hangs.Spacing.xs) {
                    ForEach(viewModel.cards) { card in
                        ProfileStatTile(card: card)
                    }
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

    // MARK: - Packs

    private var packsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            sectionLabel("custom packs")
            HangsCard {
                NavigationLink(value: AppRoute.myPacks) {
                    HangsConfigRow(label: "My packs", value: "", valueColor: Theme.Hangs.Colors.muted, showsChevron: true, action: {})
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("profile.myPacks")
            }
        }
    }

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        HangsSectionLabel(text: text)
            .padding(.horizontal, Theme.Hangs.Spacing.xxs)
    }

    private var cardPadding: EdgeInsets {
        EdgeInsets(top: Theme.Hangs.Spacing.md, leading: Theme.Hangs.Spacing.md, bottom: Theme.Hangs.Spacing.md, trailing: Theme.Hangs.Spacing.md)
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            ProfileView(viewModel: ProfileViewModel(service: MockPlayerStatsService()), isPlus: false)
        }
    }
#endif
