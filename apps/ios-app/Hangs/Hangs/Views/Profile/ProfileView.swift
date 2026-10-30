//
//  ProfileView.swift
//  Hangs
//
//  #213.4 Profile tab (founder 2026-10-28, canvas "Lišta a Profil", Profil 1),
//  reshaped by #216.3 (founder 2026-10-30, S1): the account, your plan (from
//  Home), the newest recap as one card with Share (or the first-recap
//  progress), "All stats", and Settings under the gear. My packs left the
//  Profile; they live on Play.
//

import SwiftUI

struct ProfileView<Plan: View>: View {
    @ObservedObject var viewModel: ProfileViewModel
    /// The plan from /usage, nil until it has loaded.
    var isPlus: Bool?
    /// #216.3: "your plan", moved here from Home; the caller owns its model.
    @ViewBuilder var plan: () -> Plan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xl) {
                header
                NavigationLink(value: AppRoute.settings) {
                    ProfileAccountRow(account: viewModel.account, isPlus: isPlus)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("profile.account")

                plan()

                if let recap = viewModel.latestRecap {
                    ProfileRecapCard(recap: recap, rows: viewModel.highlights(of: recap)) {
                        viewModel.shareOpened(recap)
                    }
                    .onAppear { viewModel.recapShown(recap) }
                } else if let progress = viewModel.firstRecapProgress {
                    ProfileFirstRecapCard(progress: progress)
                }

                allStatsRow
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.bottom, Theme.Hangs.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        // Also on the way back from Settings: a sign-in there renames the row.
        .onAppear(perform: viewModel.appeared)
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

    // MARK: - All stats

    private var allStatsRow: some View {
        HangsCard {
            NavigationLink(value: AppRoute.allStats) {
                HangsConfigRow(label: "All stats", value: "", valueColor: Theme.Hangs.Colors.muted, showsChevron: true, action: {})
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("profile.allStats")
        }
    }
}

extension ProfileView where Plan == EmptyView {
    /// Without the plan section (snapshots, previews).
    init(viewModel: ProfileViewModel, isPlus: Bool?) {
        self.init(viewModel: viewModel, isPlus: isPlus) { EmptyView() }
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            ProfileView(viewModel: ProfileViewModel(service: MockPlayerStatsService()), isPlus: false)
        }
    }
#endif
