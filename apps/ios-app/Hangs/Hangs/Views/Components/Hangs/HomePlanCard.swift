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
        // #194 C1: the R-Home plan card — sentence-case label, title-size
        // number, one ink meter. Same structure in every state, so the card
        // never jumps when /usage resolves (`HomePlanCardScaffold` mirrors it).
        HangsCard(padding: HomePlanCardMetrics.padding) {
            VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
                HomePlanCardLabel()
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

    // MARK: - Family A: free / free+credits / expired

    private var freeFamilyBody: some View {
        let remaining = usage.remaining ?? 0
        let credits = usage.creditBalance
        let hasCredits = credits > 0
        let showLegend = remaining > 0 && credits > 0
        let primary = hasCredits ? Self.combinedTotal(usage) : remaining

        return VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                Text(verbatim: "\(primary)")
                    .font(.hangsTitle.monospacedDigit())
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("home.planPrimary")
                planCaption(hasCredits: hasCredits)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if state == .expired {
                    planPill(text: "ended", color: Theme.Hangs.Colors.muted, icon: nil)
                }
                freeLink
            }
            if showLegend {
                legendRow(free: remaining, credits: credits)
            }
            HomePlanMeter(segments: freeTrackSegments(remaining: remaining, credits: credits))
            Text(freeMetaText(hasCredits: hasCredits))
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .accessibilityIdentifier("home.freePlanReset")
        }
    }

    /// The caption beside the number. Split out so each branch is a direct
    /// string literal — a ternary inside `Text(_:)` would resolve to the
    /// verbatim `String` initializer and pre-render the interpolation,
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
        .font(.hangsBodyLG)
        .foregroundStyle(Theme.Hangs.Colors.muted)
    }

    private func freeTrackSegments(remaining: Int, credits: Int) -> [HomePlanMeter.Segment] {
        if credits > 0 {
            let total = Double(remaining + credits)
            guard total > 0 else { return [] }
            // Free burns first: ink drawn left, cobalt credits right, widths
            // proportional to the two balances (they fill the full meter).
            return [
                .init(color: Theme.Hangs.Colors.ink, fraction: Double(remaining) / total),
                .init(color: Theme.Hangs.Colors.accentPrimary, fraction: Double(credits) / total),
            ]
        }
        // Free-only (or expired collapsed to free): a partial meter of the
        // monthly quota that is left.
        return [.init(color: Theme.Hangs.Colors.ink, fraction: HomeView.quotaFraction(usage))]
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
            linkLabel("Resubscribe", color: Theme.Hangs.Colors.actionText, id: "home.freePlanUpgrade")
        case .freeWithCredits:
            linkLabel("More", color: Theme.Hangs.Colors.actionText, id: "home.freePlanUpgrade")
        default:
            linkLabel("Upgrade", color: Theme.Hangs.Colors.actionText, id: "home.freePlanUpgrade")
        }
    }

    // MARK: - Family B: subscriber / subscriber+credits / grace

    private var subscriberBody: some View {
        VStack(alignment: .leading, spacing: HomePlanCardMetrics.rowGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                Text("Unlimited")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("home.freePlanUnlimited")
                statusPill
                    .frame(maxWidth: .infinity, alignment: .leading)
                subscriberLink
            }
            if state == .subscriberWithCredits {
                creditChip
            }
            HomePlanMeter(segments: [.init(color: subscriberTrackColor, fraction: 1)])
            subscriberMeta
        }
    }

    private var subscriberTrackColor: Color {
        state == .grace ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.ink
    }

    @ViewBuilder private var statusPill: some View {
        if state == .grace {
            planPill(text: "renewal failed", color: Theme.Hangs.Colors.warning, icon: "exclamationmark.triangle")
        } else {
            planPill(text: "active", color: Theme.Hangs.Colors.live, icon: "checkmark")
        }
    }

    private var creditChip: some View {
        Label {
            Text("\(usage.creditBalance) pack credits kept for later")
                .font(.hangsCaption)
        } icon: {
            Image(systemName: "shippingbox")
                .font(.hangsCaption)
        }
        .labelStyle(HomePlanCompactLabelStyle())
        .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
        .padding(.horizontal, Theme.Hangs.Spacing.sm)
        .padding(.vertical, Theme.Hangs.Spacing.xxs)
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
        .font(.hangsCaption)
        .foregroundStyle(Theme.Hangs.Colors.muted)
        .accessibilityIdentifier("home.planMeta")
    }

    @ViewBuilder private var subscriberLink: some View {
        if state == .grace {
            linkLabel("Fix payment", color: Theme.Hangs.Colors.warning, id: "home.planManageCTA")
        } else {
            linkLabel("Manage", color: Theme.Hangs.Colors.actionText, id: "home.planManageCTA")
        }
    }

    // MARK: - Shared pieces

    private func legendRow(free: Int, credits: Int) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.md) {
            legendItem(color: Theme.Hangs.Colors.ink, text: "\(free) monthly free")
            legendItem(color: Theme.Hangs.Colors.accentPrimary, text: "\(credits) pack credits")
        }
        .accessibilityIdentifier("home.planLegend")
    }

    private func legendItem(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            Circle().fill(color).frame(width: HomePlanCardMetrics.legendDot, height: HomePlanCardMetrics.legendDot)
            Text(text)
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
        }
    }

    private func planPill(text: LocalizedStringKey, color: Color, icon: String?) -> some View {
        Label {
            Text(text)
                .font(.hangsCaption.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("home.planStatusPill")
        } icon: {
            if let icon {
                Image(systemName: icon)
                    .font(.hangsCaption.weight(.semibold))
            }
        }
        .labelStyle(HomePlanCompactLabelStyle())
        .foregroundStyle(color)
        .padding(.horizontal, Theme.Hangs.Spacing.xs)
        .padding(.vertical, Theme.Hangs.Spacing.xxs / 2)
        .background(Capsule().fill(color.opacity(0.12)))
        .fixedSize()
    }

    private func linkLabel(_ title: LocalizedStringKey, color: Color, id: String) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            Text(title)
                .font(.hangsLabel)
                .lineLimit(1)
                .accessibilityIdentifier(id)
            Image(systemName: "chevron.right")
                .font(.hangsCaption.weight(.bold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

/// "your plan" — the label every plan-card state (and its loading/failed
/// placeholders) opens with.
struct HomePlanCardLabel: View {
    var body: some View {
        Text("your plan")
            .font(.hangsOverline)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .accessibilityIdentifier("home.planLabel")
    }
}

/// The 6pt spend meter: coloured segments drawn left→right over the track;
/// any remainder shows the empty track behind them.
struct HomePlanMeter: View {
    struct Segment {
        let color: Color
        let fraction: Double
    }

    let segments: [Segment]

    var body: some View {
        Capsule()
            .fill(Theme.Hangs.Colors.track)
            .frame(height: HomePlanCardMetrics.meterHeight)
            .overlay(alignment: .leading) {
                // In an overlay, so measuring the track never feeds its layout.
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(segments.indices, id: \.self) { index in
                            segments[index].color
                                .frame(width: proxy.size.width * min(1, max(0, segments[index].fraction)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .accessibilityHidden(true)
    }
}

/// Icon and title tight together (pills and chips on the plan card).
private struct HomePlanCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            configuration.icon.accessibilityHidden(true)
            configuration.title
        }
    }
}

enum HomePlanCardMetrics {
    static let padding = EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16)
    static let rowGap: CGFloat = 6
    static let meterHeight: CGFloat = 6
    static let legendDot: CGFloat = 6
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
