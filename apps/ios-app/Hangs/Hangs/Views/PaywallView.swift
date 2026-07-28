//
//  PaywallView.swift
//  Hangs
//
//  Two variants driven by RevenueCat offering availability (issue #93):
//    z8TS6 — subscription paywall with plan picker (issue #94): Annual card
//            pre-selected + Monthly card, one-time pack card, single CTA that
//            purchases whichever plan is selected.
//    PouwN — offline paywall ("CAN'T REACH THE STORE") shown when the offering
//            is unavailable after a completed load attempt.
//
//  Prices always come from RC `displayPrice` (locale-formatted) — never
//  hardcoded (founder decision 2026-07-11). "Restore purchases" is
//  subscription-only — the consumable pack has no StoreKit restore; its
//  balance lives server-side in the credit ledger.
//

import SwiftUI

/// The subscription plan highlighted in the z8TS6 plan picker.
enum PaywallPlan {
    case annual
    case monthly
}

struct PaywallView: View {
    @ObservedObject var storeManager: StoreManager
    let limitError: QuotaLimitError?
    let onDismiss: () -> Void

    @State private var selectedPlan: PaywallPlan

    init(
        storeManager: StoreManager,
        limitError: QuotaLimitError?,
        onDismiss: @escaping () -> Void,
        initialPlan: PaywallPlan = .annual
    ) {
        self.storeManager = storeManager
        self.limitError = limitError
        self.onDismiss = onDismiss
        _selectedPlan = State(initialValue: initialPlan)
    }

    // Offline: load attempt completed but no offering returned (store unreachable).
    var isOffline: Bool {
        storeManager.hasAttemptedOfferingsLoad && storeManager.offerings == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if isOffline {
                HangsBrandRow()
                offlineBody
            } else {
                HangsBrandRow { closeButton }
                paywallBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close", comment: "Accessibility label for the paywall close (X) button"))
        .accessibilityIdentifier("paywall-close-x-button")
    }

    // MARK: - z8TS6 — Subscription paywall (plan picker)

    private var paywallBody: some View {
        ScrollView {
            VStack(spacing: Theme.Hangs.Spacing.xl) {
                if case let .success(productID) = storeManager.purchaseState {
                    purchaseSuccessBlock(productID: productID)
                        .padding(.top, Theme.Hangs.Spacing.xxl)
                } else if case .activating = storeManager.purchaseState {
                    // #102 finding 4: RC confirmed the purchase but the server
                    // `/usage` mirror hasn't caught up yet — show "finishing
                    // activation" instead of claiming the entitlement is fully
                    // live. Does not auto-dismiss (unlike `.success` below);
                    // the user can close manually, and later reconcile passes
                    // (launch/foreground, next paywall open) catch it up.
                    activatingBlock
                        .padding(.top, Theme.Hangs.Spacing.xxl)
                } else {
                    paywallIconCircle
                        .padding(.top, Theme.Hangs.Spacing.lg)

                    paywallHeroBlock

                    if let resetDate = limitError?.resetDate {
                        CountdownPill(resetDate: resetDate)
                    }

                    planPicker

                    paywallCTAStack
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.lg)
            .padding(.bottom, Theme.Hangs.Spacing.xl)
        }
        .onAppear { storeManager.resetPurchaseState() }
        // Show the confirmation beat, then close — the paywall owns its own
        // dismissal on success (#96 P1: previously nothing did). `.task(id:)`
        // (not an unstructured Task) so SwiftUI cancels the delay on
        // disappear/state change — a stale timer must never close a paywall
        // the user reopened.
        .task(id: storeManager.purchaseState) {
            guard case .success = storeManager.purchaseState else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    // MARK: - Purchase success

    /// Post-purchase confirmation (#96 P1 — "no response" was the founder's
    /// core complaint): distinct copy per product class, auto-dismisses.
    private func purchaseSuccessBlock(productID: String?) -> some View {
        VStack(spacing: Theme.Hangs.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(Theme.Hangs.Colors.greenSoft)
                    .frame(width: 104, height: 104)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.greenCheck)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(productID == StoreProduct.packId ? "PACK ADDED" : "YOU'RE ALL SET")
                    .font(.hangsDisplayMD)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("paywall.success.headline")

                Capsule()
                    .fill(Theme.Hangs.Colors.greenCheck)
                    .frame(width: 40, height: 3)
                    .accessibilityHidden(true)

                Text(productID == StoreProduct.packId
                    ? "100 questions were added to your account."
                    : "Unlimited questions are now active.")
                    .font(.hangsBody(15))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.success.subtitle")
            }
        }
    }

    // MARK: - Finishing activation (#102 finding 4)

    /// Shown when RC confirmed the purchase but the server usage mirror
    /// hasn't yet — never claims "unlimited questions are now active" before
    /// the server gate would actually allow it.
    private var activatingBlock: some View {
        VStack(spacing: Theme.Hangs.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(Theme.Hangs.Colors.pinkSoft)
                    .frame(width: 104, height: 104)
                ProgressView()
                    .tint(Theme.Hangs.Colors.pink)
                    .scaleEffect(1.4)
            }
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("FINISHING UP")
                    .font(.hangsDisplayMD)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("paywall.activating.headline")

                Capsule()
                    .fill(Theme.Hangs.Colors.pink)
                    .frame(width: 40, height: 3)
                    .accessibilityHidden(true)

                Text("Your purchase went through. We're confirming it now, which can take a few seconds.")
                    .font(.hangsBody(15))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.activating.subtitle")
            }
        }
    }

    private var paywallIconCircle: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.pinkSoft)
                .frame(width: 104, height: 104)
            Image(systemName: "infinity")
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.pink)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("paywall.icon")
    }

    private var paywallHeroBlock: some View {
        VStack(spacing: 8) {
            // #96 P3 (founder no-wrap): single line, never the old "GO\nUNLIMITED"
            // two-line break — scales down before it would wrap.
            Text("GO UNLIMITED")
                .font(.hangsDisplayMD)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("paywall.headline")

            Capsule()
                .fill(Theme.Hangs.Colors.pink)
                .frame(width: 40, height: 3)
                .accessibilityHidden(true)

            Text(limitMessage)
                .font(.hangsBody(15))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("paywall.subtitle")
        }
    }

    // Proactive entry (#93 subscription IAP): limitError nil means the user
    // opened the paywall from Home/Settings, not by hitting the 429 quota —
    // pitch the upgrade instead of claiming they ran out.
    private var limitMessage: String {
        if let limit = limitError {
            return String(localized: "You've used all \(limit.questionsLimit) free questions this month.", comment: "Paywall subtitle when the monthly free-question limit is known")
        }
        return String(localized: "Unlimited questions for every drive, no monthly cap.", comment: "Paywall subtitle when opened proactively from Home/Settings (quota not hit)")
    }

    // MARK: - Plan picker

    /// Selection resilient to partial offerings: if the selected plan's product
    /// is missing, fall back to the other one (callers must handle partial
    /// availability — see PurchasableOfferings).
    var effectivePlan: PaywallPlan {
        switch selectedPlan {
        case .annual:
            return storeManager.offerings?.annual != nil ? .annual : .monthly
        case .monthly:
            return storeManager.offerings?.monthly != nil ? .monthly : .annual
        }
    }

    private var selectedProduct: PurchasableProduct? {
        switch effectivePlan {
        case .annual: return storeManager.offerings?.annual
        case .monthly: return storeManager.offerings?.monthly
        }
    }

    // MARK: - In-flight activity (#129 "The Button Narrates")

    /// What the store is doing right now, derived from `purchaseState` — the
    /// single source the whole in-flight paywall renders from. During any of
    /// these the CTA becomes a non-tappable status narrator and every purchase
    /// trigger dims + disables (no second purchase can start).
    private enum PaywallActivity: Equatable {
        case idle
        case purchasing(productID: String)
        case restoring
    }

    private var activity: PaywallActivity {
        switch storeManager.purchaseState {
        case let .purchasing(id): return .purchasing(productID: id)
        case .restoring: return .restoring
        default: return .idle
        }
    }

    /// True while any store operation is in flight — gates dimming + disabling.
    private var isBusy: Bool { activity != .idle }

    private func productID(for plan: PaywallPlan) -> String {
        plan == .annual ? StoreProduct.annualSubId : StoreProduct.monthlySubId
    }

    /// The plan whose subscription is the exact product being purchased (stays
    /// bright with a full check — the highlight is correct here).
    private func isPurchasing(_ plan: PaywallPlan) -> Bool {
        activity == .purchasing(productID: productID(for: plan))
    }

    private var isPurchasingPack: Bool {
        activity == .purchasing(productID: StoreProduct.packId)
    }

    /// A control recedes to 24% when the store is busy and it is not the subject
    /// of the current operation.
    private func dimmed(_ isSubject: Bool) -> Bool { isBusy && !isSubject }

    private static let dimmedOpacity: Double = 0.24
    private static let restoreFadedOpacity: Double = 0.35

    private var planPicker: some View {
        VStack(spacing: 10) {
            if let annual = storeManager.offerings?.annual {
                planCard(
                    title: "Annual",
                    price: "\(annual.displayPrice) / year",
                    badge: "SAVE 50%",
                    plan: .annual,
                    isSelected: effectivePlan == .annual
                ) {
                    selectedPlan = .annual
                }
                .accessibilityIdentifier("paywall-plan-annual")
            }

            if let monthly = storeManager.offerings?.monthly {
                planCard(
                    title: "Monthly",
                    price: "\(monthly.displayPrice) / month",
                    badge: nil,
                    plan: .monthly,
                    isSelected: effectivePlan == .monthly
                ) {
                    selectedPlan = .monthly
                }
                .accessibilityIdentifier("paywall-plan-monthly")
            }

            if let pack = storeManager.offerings?.pack {
                Text("or top up without subscribing")
                    .font(.hangsBody(12, weight: .medium))
                    .foregroundColor(Theme.Hangs.Colors.mutedFaint)
                    .padding(.top, 2)
                    // Recedes while any purchase/restore is in flight — the pack
                    // is no longer the offered path while something is buying.
                    .opacity(isBusy ? Self.dimmedOpacity : 1)

                packCard(pack)
            }
        }
    }

    /// The pink selection radio, demoted (#129 decision 2) to a hollow outline
    /// when the card stays selected while a *different* product is in flight.
    private enum PlanCheck { case none, solid, hollow }

    private func planCard(
        title: LocalizedStringKey,
        price: LocalizedStringKey,
        badge: LocalizedStringKey?,
        plan: PaywallPlan,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        // Bright only when idle or when this plan's subscription is the exact
        // product being bought; otherwise recede to 24% (#129).
        let isSubject = isPurchasing(plan)
        let isDimmed = dimmed(isSubject)
        let check: PlanCheck = isSelected ? (isDimmed ? .hollow : .solid) : .none
        return Button(action: action) {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.hangsBody(16, weight: .bold))
                            .foregroundColor(Theme.Hangs.Colors.ink)
                        if let badge {
                            Text(badge)
                                .font(.hangsBody(10, weight: .bold))
                                .kerning(0.5)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Theme.Hangs.Colors.pink))
                        }
                    }
                    Text(price)
                        .font(.hangsBody(13))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                }
                Spacer()
                planRadio(check)
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.subtleBorder,
                        lineWidth: isSelected ? 2 : 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? Self.dimmedOpacity : 1)
        // No plan selection change (or a second purchase) may start while a
        // store operation is in flight — reentrancy is impossible (#129).
        .disabled(isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func planRadio(_ style: PlanCheck) -> some View {
        ZStack {
            switch style {
            case .solid:
                Circle()
                    .fill(Theme.Hangs.Colors.pink)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            case .hollow:
                // Demoted: pink outline + pink check, still readable as "this is
                // what you'd buy next" without competing with the busy product.
                Circle()
                    .strokeBorder(Theme.Hangs.Colors.pink, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.Hangs.Colors.pink)
            case .none:
                Circle()
                    .strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    /// One-time consumable pack — tapping the card purchases directly (the
    /// primary CTA is subscription-only per z8TS6). Drawn deliberately lighter
    /// than the plan cards (smaller title, tighter padding, smaller price pill)
    /// so it reads as the secondary escape hatch it is (#129 idle spec).
    private func packCard(_ pack: PurchasableProduct) -> some View {
        // The pack is the "source" of the busy state while it is being bought:
        // no row spinner — the purple filled pill + leading dot point at it, and
        // the purple narrating CTA does the same (#129). Otherwise it dims.
        let isSource = isPurchasingPack
        let isDimmed = dimmed(isSource)
        return Button {
            Task { await storeManager.purchase(productID: pack.id) }
        } label: {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                if isSource {
                    Circle()
                        .fill(Theme.Hangs.Colors.accentPrimary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("100 Question Pack")
                        .font(.hangsBody(14, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                    Text("One-time purchase · never expires")
                        .font(.hangsBody(12))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                }
                Spacer()
                Text(verbatim: pack.displayPrice)
                    .font(.hangsBody(13, weight: .bold))
                    .foregroundColor(isSource ? .white : Theme.Hangs.Colors.accentPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minHeight: 30)
                    .background(
                        Capsule().fill(
                            isSource ? Theme.Hangs.Colors.accentPrimary : Theme.Hangs.Colors.accentPrimarySoft
                        )
                    )
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? Self.dimmedOpacity : 1)
        // Disabled whenever busy: while it is the source (already buying) and
        // while another product is in flight — no overlapping purchase (#129).
        .disabled(isBusy)
        .accessibilityIdentifier("paywall-purchase-pack-button")
    }

    // MARK: - CTA stack

    /// The single status surface (#129 "The Button Narrates"): the Subscribe CTA
    /// while idle, and — while a purchase or restore is in flight — a tinted,
    /// non-tappable narrator that spells out exactly what is happening. It never
    /// looks like a dead Subscribe button because it changes colour and copy.
    @ViewBuilder
    private var ctaButton: some View {
        switch activity {
        case let .purchasing(id) where id == StoreProduct.packId:
            // Purple: the pack. Literal label mirrors the pack row's own title
            // (#56 — never interpolate RC's runtime product name into a key).
            PaywallNarratingCTA(title: "Buying 100 Question Pack…", tint: Theme.Hangs.Colors.accentPrimary)
                .accessibilityIdentifier("paywall-cta-narrating")
        case let .purchasing(id) where id == StoreProduct.annualSubId:
            PaywallNarratingCTA(
                title: "Buying Annual — \(annualPriceString) / year…",
                tint: Theme.Hangs.Colors.pink
            )
            .accessibilityIdentifier("paywall-cta-narrating")
        case let .purchasing(id) where id == StoreProduct.monthlySubId:
            PaywallNarratingCTA(
                title: "Buying Monthly — \(monthlyPriceString) / month…",
                tint: Theme.Hangs.Colors.pink
            )
            .accessibilityIdentifier("paywall-cta-narrating")
        case .restoring:
            // Blue: restore acts on the account, not a product.
            PaywallNarratingCTA(title: "Restoring purchases…", tint: Theme.Hangs.Colors.blue)
                .accessibilityIdentifier("paywall-cta-narrating")
        default:
            subscribeButton
        }
    }

    /// The idle Subscribe CTA — buys the selected plan. No longer consumes the
    /// global `storeManager.isLoading`: the in-flight window is the narrating CTA
    /// above, so this button is only ever shown while idle (#129 scope A).
    @ViewBuilder
    private var subscribeButton: some View {
        if let product = selectedProduct {
            // #56: title param is LocalizedStringKey; pass the interpolated
            // literal directly so the compiler extracts "Subscribe — %@ / year"
            // (the displayPrice is a runtime placeholder, not translatable).
            if effectivePlan == .annual {
                HangsPrimaryButton(title: "Subscribe — \(product.displayPrice) / year", height: 52) {
                    Task { await storeManager.purchase(productID: product.id) }
                }
                .accessibilityIdentifier("paywall-purchase-button")
            } else {
                HangsPrimaryButton(title: "Subscribe — \(product.displayPrice) / month", height: 52) {
                    Task { await storeManager.purchase(productID: product.id) }
                }
                .accessibilityIdentifier("paywall-purchase-button")
            }
        } else {
            // Offerings not yet loaded — the load placeholder (out of #129 scope).
            HangsPrimaryButton(title: "Subscribe", isLoading: true, height: 52) {}
                .accessibilityIdentifier("paywall-purchase-button")
        }
    }

    /// Locale-formatted subscription prices for the narrating CTA (empty only in
    /// the impossible case of an in-flight product with no matching offering).
    private var annualPriceString: String { storeManager.offerings?.annual?.displayPrice ?? "" }
    private var monthlyPriceString: String { storeManager.offerings?.monthly?.displayPrice ?? "" }

    private var paywallCTAStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            ctaButton

            HangsGhostButton(
                title: "Restore purchases",
                color: Theme.Hangs.Colors.blue,
                font: .hangsBody(14, weight: .semibold)
            ) {
                Task { await storeManager.restorePurchases() }
            }
            // Fades in place while any store op is in flight (#129) — including
            // its own restore, which the blue narrating CTA reports instead.
            .opacity(isBusy ? Self.restoreFadedOpacity : 1)
            .disabled(isBusy)
            .accessibilityIdentifier("paywall-restore-button")

            HangsGhostButton(
                title: "Maybe tomorrow",
                color: Theme.Hangs.Colors.muted,
                font: .hangsBody(14)
            ) {
                onDismiss()
            }
            .accessibilityIdentifier("paywall-close-button")

            if let error = storeManager.purchaseError {
                Text(error)
                    .font(.hangsBody(13))
                    .foregroundColor(Theme.Hangs.Colors.error)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.purchaseError")
            }

            if storeManager.purchaseState == .pending {
                Text("Purchase is awaiting approval. You'll get access as soon as it's approved.")
                    .font(.hangsBody(13))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.pendingNotice")
            }

            if storeManager.purchaseState == .nothingToRestore {
                Text("No previous purchase found for this Apple Account.")
                    .font(.hangsBody(13))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.nothingToRestore")
            }

            // App Store review requirement: auto-renew disclosure (z8TS6 legal).
            Text("Auto-renews until cancelled. Cancel anytime in Settings.")
                .font(.hangsBody(11))
                .foregroundColor(Theme.Hangs.Colors.mutedFaint)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
                .accessibilityIdentifier("paywall.legal")
        }
    }

    // MARK: - PouwN — Can't Reach The Store

    private var offlineBody: some View {
        VStack(spacing: Theme.Hangs.Spacing.xl) {
            Spacer(minLength: Theme.Hangs.Spacing.xxl)

            offlineIconCircle

            offlineHeroBlock

            Spacer()

            offlineCTAStack
                .padding(.horizontal, Theme.Hangs.Spacing.lg)
                .padding(.bottom, Theme.Hangs.Spacing.xl)
        }
    }

    private var offlineIconCircle: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.warning.opacity(0.12))
                .frame(width: 120, height: 120)
            Image(systemName: "wifi.slash")
                .font(.system(size: 44, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.warning)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("paywall.offline.icon")
    }

    private var offlineHeroBlock: some View {
        VStack(spacing: 8) {
            Text("CAN'T REACH\nTHE STORE")
                .font(.hangsDisplayMD)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("paywall.offline.headline")

            Capsule()
                .fill(Theme.Hangs.Colors.warning)
                .frame(width: 40, height: 3)
                .accessibilityHidden(true)

            Text("We couldn't load the upgrade right now. Check your connection and try again.")
                .font(.hangsBody(15))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("paywall.offline.subtitle")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
    }

    private var offlineCTAStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            HangsPrimaryButton(title: "Try Again", icon: "arrow.clockwise") {
                Task { await storeManager.loadOfferings() }
            }
            .accessibilityIdentifier("paywall-offline-retry-button")

            HangsSecondaryButton(title: "Maybe tomorrow") {
                onDismiss()
            }
            .accessibilityIdentifier("paywall-close-button")
        }
    }
}

// MARK: - Narrating CTA (#129 "The Button Narrates")

/// The in-flight status surface for the paywall: a tinted pill that names the
/// product being processed, with an indeterminate progress track along the
/// bottom edge. Deliberately NOT a `Button` — it is a status, not a control, so
/// it is non-tappable by construction, and because it changes colour + copy it
/// never reads as a greyed-out dead Subscribe button (issue #129, decision 1).
private struct PaywallNarratingCTA: View {
    let title: LocalizedStringKey
    let tint: Color
    var height: CGFloat = 52

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        Text(title)
            // Hero-text rule (#96 P3): single line, scale down before wrapping —
            // "Buying 100 Question Pack…" must never break to two lines.
            .font(.hangsButton)
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                ZStack(alignment: .bottom) {
                    Capsule().fill(tint)
                    indeterminateTrack
                }
                .clipShape(Capsule())
            )
            .hangsShadow(Theme.Hangs.Shadow.cta)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(.updatesFrequently)
    }

    /// A thin segment that slides back and forth along the bottom edge — an
    /// indeterminate "working" signal, no spinner. Honors Reduce Motion by
    /// resting static rather than looping.
    private var indeterminateTrack: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let segmentWidth = trackWidth * 0.35
            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: segmentWidth, height: 3)
                .offset(x: animating ? trackWidth - segmentWidth : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: animating
                )
        }
        .frame(height: 3)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .onAppear { animating = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Countdown Pill

private struct CountdownPill: View {
    let resetDate: Date
    @State private var timeRemaining: String = ""
    @State private var timer: Timer?

    var body: some View {
        Text(String(localized: "Free questions reset in \(timeRemaining)", comment: "Countdown pill: time until free questions reset"))
            .font(.hangsMono(10, weight: .medium))
            .kerning(1)
            .textCase(.uppercase)
            .foregroundColor(Theme.Hangs.Colors.bg)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(Theme.Hangs.Colors.ink))
            .onAppear { startTimer() }
            .onDisappear { timer?.invalidate() }
            .accessibilityIdentifier("paywall.countdownPill")
    }

    private func startTimer() {
        updateCountdown()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            updateCountdown()
        }
    }

    private func updateCountdown() {
        let remaining = resetDate.timeIntervalSince(Date())
        guard remaining > 0 else {
            timeRemaining = String(localized: "now", comment: "Countdown pill value when free questions reset imminently")
            return
        }
        let days = Int(remaining) / 86400
        let hours = (Int(remaining) % 86400) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if days > 0 {
            timeRemaining = String(localized: "\(days)d \(hours)h", comment: "Compact time remaining: days and hours (e.g. 12d 4h)")
        } else if hours > 0 {
            timeRemaining = String(localized: "\(hours)h \(minutes)m", comment: "Compact time remaining: hours and minutes (e.g. 3h 5m)")
        } else {
            timeRemaining = String(localized: "\(minutes)m", comment: "Compact time remaining: minutes only (e.g. 5m)")
        }
    }
}

// MARK: - Helper extension

private extension QuotaLimitError {
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }
}
