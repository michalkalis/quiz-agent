//
//  HomePlanCard.swift
//  Hangs
//
//  #123 Track B — the adaptive Home entitlement card (Variant A "One adaptive
//  balance card", founder pick 2026-07-28). One surface, six visuals, derived
//  purely from `UsageInfo`. The card learns to say more; nothing is added to
//  Home. See docs/design/variants/issue-123B-home-entitlement-states.html.
//
//  Presentation only: the whole-card tap target and its state-dependent
//  destination (paywall vs. manage-subscription) live in HomeView, which wraps
//  this in a single Button. This view never taps, fetches, or grants.
//

import SwiftUI

struct HomePlanCard: View {
    let usage: UsageInfo

    // MARK: - Derived state

    /// The six card visuals. `subscriptionStatus` ("active"|"grace"|"expired"|
    /// "none") is authoritative for grace/expired — a grace subscriber may
    /// still read `isPremium == true`, and an expired one has already collapsed
    /// back to the free tier. `creditBalance` splits the two "active" visuals
    /// and folds into the free total otherwise.
    enum PlanState: Equatable {
        case free
        case freeWithCredits
        case subscriber
        case subscriberWithCredits
        case grace
        case expired

        /// Family B (active/grace) taps through to the manage-subscription
        /// surface; family A (free/expired) taps through to the paywall.
        var isManageSurface: Bool {
            switch self {
            case .subscriber, .subscriberWithCredits, .grace: true
            case .free, .freeWithCredits, .expired: false
            }
        }
    }

    /// Maps the fetched usage onto one card visual. Pure + static so the
    /// state-derivation contract is unit-testable without hosting the view.
    static func state(for usage: UsageInfo) -> PlanState {
        switch usage.subscriptionStatus {
        case "grace": return .grace
        case "expired": return .expired
        default: break
        }
        if usage.isPremium || usage.subscriptionStatus == "active" {
            return usage.creditBalance > 0 ? .subscriberWithCredits : .subscriber
        }
        return usage.creditBalance > 0 ? .freeWithCredits : .free
    }

    /// Total spendable questions when monthly free quota and pack credits
    /// coexist — the number a free credit-holder actually reads on Home.
    static func combinedTotal(_ usage: UsageInfo) -> Int {
        (usage.remaining ?? 0) + usage.creditBalance
    }

    private var state: PlanState { Self.state(for: usage) }

    // MARK: - Body

    var body: some View {
        HangsCard(padding: .init(top: 12, leading: 16, bottom: 12, trailing: 16)) {
            VStack(alignment: .leading, spacing: 8) {
                planLabel
                switch state {
                case .subscriber, .subscriberWithCredits, .grace:
                    subscriberBody
                case .free, .freeWithCredits, .expired:
                    freeFamilyBody
                }
            }
        }
        .accessibilityIdentifier("home.freePlanCard")
    }

    // MARK: - Shared header

    private var planLabel: some View {
        Text("your plan")
            .font(.hangsMono(11, weight: .medium))
            .tracking(1)
            .foregroundColor(Theme.Hangs.Colors.blueText)
            .accessibilityIdentifier("home.planLabel")
    }

    // MARK: - Family A: free / free+credits / expired

    private var freeFamilyBody: some View {
        let remaining = usage.remaining ?? 0
        let credits = usage.creditBalance
        let hasCredits = credits > 0
        let showLegend = remaining > 0 && credits > 0
        let primary = hasCredits ? Self.combinedTotal(usage) : remaining

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(primary)")
                    .font(.hangsDisplay(40))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("home.planPrimary")
                planCaption(hasCredits: hasCredits)
                Spacer(minLength: 0)
                if state == .expired {
                    planPill(text: "ended", color: Theme.Hangs.Colors.pinkText, icon: nil)
                }
            }
            if showLegend {
                legendRow(free: remaining, credits: credits)
            }
            planTrack(segments: freeTrackSegments(remaining: remaining, credits: credits))
            HStack {
                Text(freeMetaText(hasCredits: hasCredits))
                    .font(.hangsBody(12))
                    .foregroundColor(Theme.Hangs.Colors.mutedFaint)
                    .accessibilityIdentifier("home.freePlanReset")
                Spacer()
                freeLink
            }
        }
    }

    /// The muted caption beside the Anton headline. Split out so each branch is
    /// a direct string literal — a ternary inside `Text(_:)` would resolve to
    /// the verbatim `String` initializer and pre-render the interpolation,
    /// dropping the "%lld" from the localization catalog (#56).
    @ViewBuilder
    private func planCaption(hasCredits: Bool) -> some View {
        Group {
            if hasCredits {
                Text("questions available")
                    .accessibilityIdentifier("home.planCaption")
            } else {
                Text("of \(usage.questionsLimit ?? 0) free questions left")
                    .accessibilityIdentifier("home.planCaption")
            }
        }
        .font(.hangsBody(13, weight: .semibold))
        .foregroundColor(Theme.Hangs.Colors.muted)
    }

    private func freeTrackSegments(remaining: Int, credits: Int) -> [(Color, Double)] {
        if credits > 0 {
            let total = Double(remaining + credits)
            guard total > 0 else { return [] }
            // Free burns first: blue segment drawn left, purple right, widths
            // proportional to the two balances (they fill the full track).
            return [
                (Theme.Hangs.Colors.blue, Double(remaining) / total),
                (Theme.Hangs.Colors.accentPrimary, Double(credits) / total),
            ]
        }
        // Free-only (or expired collapsed to free): a partial blue meter of the
        // monthly quota that is left.
        return [(Theme.Hangs.Colors.blue, HomeView.quotaFraction(usage))]
    }

    /// "resets in 3 days" — and, when pack credits coexist, that they don't
    /// expire with the monthly reset.
    private func freeMetaText(hasCredits: Bool) -> String {
        let base = HomeView.resetCountdown(usage)
            ?? String(localized: "resets soon", comment: "Home plan card: free questions reset in under an hour")
        guard hasCredits else { return base }
        return String(
            localized: "\(base) · credits never expire",
            comment: "Home plan card meta when a free user also holds pack credits: reset countdown plus that credits don't expire"
        )
    }

    @ViewBuilder private var freeLink: some View {
        switch state {
        case .expired:
            linkLabel("Resubscribe", color: Theme.Hangs.Colors.pink, id: "home.freePlanUpgrade")
        case .freeWithCredits:
            linkLabel("More", color: Theme.Hangs.Colors.pink, id: "home.freePlanUpgrade")
        default:
            linkLabel("Upgrade", color: Theme.Hangs.Colors.pink, id: "home.freePlanUpgrade")
        }
    }

    // MARK: - Family B: subscriber / subscriber+credits / grace

    private var subscriberBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Unlimited")
                    .font(.hangsDisplay(32))
                    .textCase(.uppercase)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityIdentifier("home.freePlanUnlimited")
                statusPill
                Spacer(minLength: 0)
            }
            if state == .subscriberWithCredits {
                creditChip
            }
            planTrack(segments: [(subscriberTrackColor, 1.0)])
            HStack {
                subscriberMeta
                Spacer()
                subscriberLink
            }
        }
    }

    private var subscriberTrackColor: Color {
        state == .grace ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.pink
    }

    @ViewBuilder private var statusPill: some View {
        if state == .grace {
            planPill(text: "renewal failed", color: Theme.Hangs.Colors.warning, icon: "exclamationmark.triangle.fill")
        } else {
            planPill(text: "active", color: Theme.Hangs.Colors.successText, icon: "checkmark")
        }
    }

    private var creditChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text("\(usage.creditBalance) pack credits kept for later")
                .font(.hangsBody(12, weight: .medium))
        }
        .foregroundColor(Theme.Hangs.Colors.accentPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.Hangs.Colors.accentPrimarySoft))
        .accessibilityIdentifier("home.planCreditChip")
    }

    @ViewBuilder private var subscriberMeta: some View {
        Group {
            if state == .grace {
                Text("Update your payment method")
            } else {
                // No renewal date in the /usage payload (#123): the model can't
                // say "renews 12 Aug", so state the status honestly instead.
                Text("Subscription active")
            }
        }
        .font(.hangsBody(12))
        .foregroundColor(Theme.Hangs.Colors.mutedFaint)
        .accessibilityIdentifier("home.planMeta")
    }

    @ViewBuilder private var subscriberLink: some View {
        if state == .grace {
            linkLabel("Fix payment", color: Theme.Hangs.Colors.warning, id: "home.planManageCTA")
        } else {
            linkLabel("Manage", color: Theme.Hangs.Colors.pink, id: "home.planManageCTA")
        }
    }

    // MARK: - Shared pieces

    private func legendRow(free: Int, credits: Int) -> some View {
        HStack(spacing: 14) {
            legendItem(color: Theme.Hangs.Colors.blue, text: "\(free) monthly free")
            legendItem(color: Theme.Hangs.Colors.accentPrimary, text: "\(credits) pack credits")
        }
        .accessibilityIdentifier("home.planLegend")
    }

    private func legendItem(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.hangsBody(11, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.muted)
        }
    }

    /// A capsule spend meter. One or more coloured segments drawn left→right
    /// over the subtle track; any remainder shows the empty track behind them.
    private func planTrack(segments: [(Color, Double)]) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Hangs.Colors.subtleBorder)
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.0)
                            .frame(width: max(0, geo.size.width * min(1, segment.1)))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func planPill(text: LocalizedStringKey, color: Color, icon: String?) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.hangsBody(11, weight: .semibold))
                .accessibilityIdentifier("home.planStatusPill")
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private func linkLabel(_ title: LocalizedStringKey, color: Color, id: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.hangsBody(13, weight: .semibold))
                .accessibilityIdentifier(id)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundColor(color)
    }
}

#if DEBUG
    private func previewUsage(
        premium: Bool = false,
        remaining: Int? = 12,
        limit: Int? = 30,
        status: String = "none",
        credits: Int = 0
    ) -> UsageInfo {
        UsageInfo(
            userId: "preview", isPremium: premium, questionsUsed: 18,
            questionsLimit: premium ? nil : limit, remaining: premium ? nil : remaining,
            resetsAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400)),
            subscriptionStatus: status, creditBalance: credits
        )
    }

    #Preview {
        ScrollView {
            VStack(spacing: 16) {
                HomePlanCard(usage: previewUsage())
                HomePlanCard(usage: previewUsage(credits: 100))
                HomePlanCard(usage: previewUsage(premium: true, status: "active"))
                HomePlanCard(usage: previewUsage(premium: true, status: "active", credits: 100))
                HomePlanCard(usage: previewUsage(premium: true, status: "grace"))
                HomePlanCard(usage: previewUsage(remaining: 30, limit: 30, status: "expired"))
            }
            .padding(20)
        }
        .background(Theme.Hangs.Colors.bg)
    }
#endif
