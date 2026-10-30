//
//  PlanSection.swift
//  Hangs
//
//  #216.3 (founder 2026-10-30): "your plan" moved from Home to the Profile
//  tab, under the account row. The card, its states and its taps are the ones
//  Home had (#87 · #123 Track B); the identifiers keep their `home.` names.
//

import SwiftUI
import UIKit

struct PlanSection: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            HangsSectionLabel(text: "your plan")
                .padding(.horizontal, Theme.Hangs.Spacing.xxs)
                .accessibilityIdentifier("home.planLabel")
            freePlanCard
        }
        .task { await viewModel.refreshUsage() }
    }

    // The adaptive balance card (Variant A): one surface, one whole-card tap
    // target, six visuals derived from UsageInfo — free · free+credits ·
    // subscriber · subscriber+credits · grace · expired (rendered by
    // `HomePlanCard`). The tap destination forks by state: family A (free /
    // free+credits / expired) opens the paywall; family B (active / grace)
    // opens the manage-subscription surface.
    // #123 Track A: the slot is never silently blank — while /usage is still
    // in flight it shows a loading placeholder instead of disappearing.
    @ViewBuilder
    private var freePlanCard: some View {
        if let usage = viewModel.usageInfo {
            if HomePlanCard.state(for: usage).isManageSurface {
                Button {
                    openManageSubscriptions()
                } label: {
                    HomePlanCard(usage: usage)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.planManageButton")
            } else {
                Button {
                    viewModel.presentPaywall(source: .profile)
                } label: {
                    HomePlanCard(usage: usage)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.freePlanUpgradeButton")
            }
        } else if viewModel.usageLoadState == .failed {
            // Fetch failed with nothing cached (typically a Fly cold start) —
            // show a lightweight retry placeholder instead of silently
            // vanishing (#FIX2, CLAUDE.md Rule #2 fail-loud).
            freePlanCardUnavailable
        } else {
            // #123: still loading (the launch/foreground fetch hasn't
            // resolved yet).
            freePlanCardLoading
        }
    }

    /// Manage-subscription destination for an active/grace subscriber (#123
    /// Track B). The standard App Store account-subscriptions URL is the
    /// simplest reliable surface: it's one hop and needs no live UIWindowScene,
    /// unlike StoreKit's `AppStore.showManageSubscriptions(in:)`.
    private func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    // Shown only while /usage's launch/foreground fetch is still in flight and
    // nothing is cached yet (#123 Track A). Holds the loaded card's full
    // scaffold — a number-height spinner row, then an empty meter beside a
    // skeleton meta line — so the slot doesn't jump when /usage resolves into
    // the loaded (or failed) state.
    private var freePlanCardLoading: some View {
        HangsCard(padding: HomePlanCardMetrics.padding) {
            VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                    Text(verbatim: "00")
                        .font(.hangsTitle)
                        .hidden()
                        .overlay(alignment: .leading) {
                            ProgressView().tint(Theme.Hangs.Colors.muted)
                        }
                    Text("Loading your plan…")
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                }
                HomePlanMeterRow(meter: HomePlanMeter(segments: [])) {
                    Text(verbatim: "resets in 13 days")
                        .font(.hangsCaption)
                        .hidden()
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.Hangs.Colors.track)
                        }
                        .accessibilityIdentifier("home.planLoadingSkeleton")
                }
            }
        }
        .accessibilityIdentifier("home.freePlanLoading")
    }

    // Shown only when /usage failed to load and there is nothing cached — a
    // tap re-fetches. Reuses the plan card surface; no new design system.
    private var freePlanCardUnavailable: some View {
        Button {
            Task { await viewModel.refreshUsage() }
        } label: {
            HangsCard(padding: HomePlanCardMetrics.padding) {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    Image(systemName: "bolt.slash")
                        .font(.hangsCaption.weight(.semibold))
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .accessibilityHidden(true)
                    Text("Couldn't load your plan")
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
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
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.freePlanRetryButton")
    }
}
