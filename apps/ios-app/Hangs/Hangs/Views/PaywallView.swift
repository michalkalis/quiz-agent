//
//  PaywallView.swift
//  Hangs
//
//  Two variants driven by RevenueCat offering availability (issue #93):
//    z8TS6 — subscription paywall (monthly-only for v1, founder 2026-09-18):
//            Monthly card + one-time pack card, single CTA that purchases
//            whichever is selected.
//    PouwN — offline paywall ("CAN'T REACH THE STORE") shown when the offering
//            is unavailable after a completed load attempt.
//
//  #194 C6: restyled to "Sklo nad kartami" — glass ✕, a small card stack,
//  cobalt for the chosen plan, one ink CTA (spinner while buying) at the
//  bottom. Behaviour and copy are the beta's.
//
//  Prices always come from RC `displayPrice` (locale-formatted) — never
//  hardcoded (founder decision 2026-07-11). "Restore purchases" is
//  subscription-only — the consumable pack has no StoreKit restore; its
//  balance lives server-side in the credit ledger.
//

import SwiftUI

/// What the picker has selected — the one thing the bottom CTA buys. #179
/// finding 9 folded the one-time pack in here: it used to buy itself the
/// instant it was tapped, which is not what a card in a picker means.
enum PaywallPlan {
    case monthly
    case pack
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
        initialPlan: PaywallPlan = .monthly
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
            // #179 finding 9: the offline variant lost "Maybe tomorrow" too,
            // so it needs the ✕ — otherwise "Try Again" is the only control
            // on screen and the user is stuck behind an unreachable store.
            HangsBrandRow { closeButton }
            if isOffline {
                offlineBody
            } else {
                paywallBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
    }

    private var closeButton: some View {
        HangsNavChip(icon: "xmark", label: "Close", action: onDismiss)
            .accessibilityIdentifier("paywall-close-x-button")
    }

    // MARK: - z8TS6 — Subscription paywall (plan picker)

    private var paywallBody: some View {
        // The CTA stack sits at the bottom while everything fits and follows
        // the content when it doesn't (large text); the reader is outside the
        // scroll view, so measuring never feeds its own layout.
        GeometryReader { viewport in
            ScrollView {
                paywallContent
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .padding(.bottom, Theme.Hangs.Spacing.md)
                    .frame(minHeight: viewport.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
                    // #102 finding 4: RC confirmed the purchase but the server
                    // `/usage` mirror hasn't caught up yet — show "finishing
                    // activation" instead of claiming the entitlement is fully
                    // live. Does not auto-dismiss (unlike `.success` below);
                    // the user can close manually, and later reconcile passes
                    // (launch/foreground, next paywall open) catch it up.
    }

    @ViewBuilder
    private var paywallContent: some View {
        VStack(spacing: Theme.Hangs.Spacing.md) {
            if case let .success(productID) = storeManager.purchaseState {
                Spacer(minLength: Theme.Hangs.Spacing.xxl)
                purchaseSuccessBlock(productID: productID)
                Spacer(minLength: Theme.Hangs.Spacing.xxl)
            } else if case .activating = storeManager.purchaseState {
                Spacer(minLength: Theme.Hangs.Spacing.xxl)
                activatingBlock
                Spacer(minLength: Theme.Hangs.Spacing.xxl)
            } else {
                paywallIconCircle

                paywallHeroBlock

                if let resetDate = limitError?.resetDate {
                    CountdownPill(resetDate: resetDate)
                }

                planPicker
                    .padding(.top, Theme.Hangs.Spacing.xs)

                Spacer(minLength: Theme.Hangs.Spacing.sm)

                paywallCTAStack
            }
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
            PaywallHeroDeck(fills: Self.deckFills) {
                PaywallBadge(tint: Theme.Hangs.Colors.live) {
                    Image(systemName: "checkmark")
                }
            }

            VStack(spacing: Theme.Hangs.Spacing.sm) {
                Text(productID == StoreProduct.packId ? "PACK ADDED" : "YOU'RE ALL SET")
                    .font(.hangsDisplaySM)
                    .hangsHeadlineFit()
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("paywall.success.headline")

                Text(productID == StoreProduct.packId
                    ? "100 questions were added to your account."
                    : "Unlimited questions are now active.")
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
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
            PaywallHeroDeck(fills: Self.deckFills) {
                PaywallBadge(tint: Theme.Hangs.Colors.ink) {
                    ProgressView().tint(Theme.Hangs.Colors.ink)
                }
            }

            VStack(spacing: Theme.Hangs.Spacing.sm) {
                Text("FINISHING UP")
                    .font(.hangsDisplaySM)
                    .hangsHeadlineFit()
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("paywall.activating.headline")

                Text("Your purchase went through. We're confirming it now, which can take a few seconds.")
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.activating.subtitle")
            }
        }
    }

    /// Category cards behind the paywall glyphs (canvas: mandarin, green, cobalt).
    private static var deckFills: [Color] {
        ["history", "science-nature", "geography-world"].map { Theme.Hangs.Category.style(for: $0).fill }
    }

    private var paywallIconCircle: some View {
        PaywallHeroDeck(fills: Self.deckFills) {
            Image(systemName: "infinity")
                .font(.hangsHeading)
                .foregroundStyle(Theme.Hangs.Category.style(for: "geography-world").text)
        }
        .accessibilityIdentifier("paywall.icon")
    }

    private var paywallHeroBlock: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            // #96 P3 (founder no-wrap): single line, never the old "GO\nUNLIMITED"
            // two-line break — scales down before it would wrap.
            Text("GO UNLIMITED")
                .font(.hangsDisplaySM)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("paywall.headline")

            Text(limitMessage)
                .font(.hangsBodyLG)
                .foregroundStyle(Theme.Hangs.Colors.muted)
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
        return String(localized: "Unlimited questions, no monthly cap.", comment: "Paywall subtitle when opened proactively from Home/Settings (quota not hit)")
    }

    // MARK: - Plan picker

    private var picker: PaywallPickerState {
        PaywallPickerState(
            selectedPlan: selectedPlan,
            offerings: storeManager.offerings,
            purchaseState: storeManager.purchaseState
        )
    }

    var effectivePlan: PaywallPlan { picker.effectivePlan }

    private var isBusy: Bool { picker.isBusy }

    private static let dimmedOpacity: Double = 0.24
    private static let restoreFadedOpacity: Double = 0.35

    private var planPicker: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            if let monthly = storeManager.offerings?.monthly {
                planCard(
                    title: "Monthly",
                    price: "\(monthly.displayPrice) / month",
                    plan: .monthly,
                    isSelected: effectivePlan == .monthly
                ) {
                    selectedPlan = .monthly
                }
                .accessibilityIdentifier("paywall-plan-monthly")
            }

            if let pack = storeManager.offerings?.pack {
                Text("or top up without subscribing")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    // Recedes while any purchase/restore is in flight — the pack
                    // is no longer the offered path while something is buying.
                    .opacity(isBusy ? Self.dimmedOpacity : 1)

                packCard(pack)
            }
        }
    }

    /// #194 C6: the chosen plan is a cobalt card with white type (the
    /// selection colour app-wide); the other one stays a white card.
    private func planSurface(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
            .fill(isSelected ? Theme.Hangs.Colors.accentPrimary : Theme.Hangs.Colors.bgCard)
            .strokeBorder(isSelected ? Color.clear : Theme.Hangs.Colors.hairline)
    }

    private func planCard(
        title: LocalizedStringKey,
        price: LocalizedStringKey,
        plan: PaywallPlan,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        // Bright only when idle or when this plan's subscription is the exact
        // product being bought; otherwise recede to 24% (#129).
        let isDimmed = picker.isDimmed(plan)
        let check = picker.check(for: plan)
        // a11y-id: call-site — the identifier belongs to the screen that places this component
        return Button(action: action) {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs / 2) {
                    Text(title)
                        .font(.hangsHeading)
                    Text(price)
                        .font(.hangsLabel)
                        .opacity(isSelected ? 0.85 : 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                planRadio(check, onCobalt: isSelected)
            }
            .foregroundStyle(isSelected ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.md)
            .frame(minHeight: Metrics.planMinHeight)
            .background(planSurface(isSelected: isSelected))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? Self.dimmedOpacity : 1)
        // No plan selection change (or a second purchase) may start while a
        // store operation is in flight — reentrancy is impossible (#129).
        .disabled(isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func planRadio(_ style: PaywallPickerState.Check, onCobalt: Bool) -> some View {
        ZStack {
            switch style {
            case .solid:
                Circle()
                    .fill(Theme.Hangs.Colors.textOnAccent)
                Image(systemName: "checkmark")
                    .font(.hangsCaption.weight(.bold))
                    .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
            case .hollow:
                // Demoted: an outline + check, still readable as "this is what
                // you'd buy next" without competing with the busy product.
                Circle()
                    .strokeBorder(onCobalt ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.accentPrimary, lineWidth: Metrics.ringWidth)
                Image(systemName: "checkmark")
                    .font(.hangsCaption.weight(.bold))
                    .foregroundStyle(onCobalt ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.accentPrimary)
            case .none:
                Circle()
                    .strokeBorder(Theme.Hangs.Colors.track, lineWidth: Metrics.ringWidth)
            }
        }
        .frame(width: Metrics.radio, height: Metrics.radio)
        .accessibilityHidden(true)
    }

    /// One-time consumable pack. #179 finding 9: tapping it used to start the
    /// purchase outright — a card sitting in a picker, next to two cards that
    /// only select, that charged you instead. It SELECTS now, like the plan
    /// cards, and the bottom CTA is the only thing that buys. Still drawn
    /// lighter than the plan card (smaller title, price pill) so it reads as
    /// the secondary path it is.
    private func packCard(_ pack: PurchasableProduct) -> some View {
        let isSelected = effectivePlan == .pack
        let isSource = picker.isPurchasing(.pack)
        let isDimmed = picker.isDimmed(.pack)
        let check = picker.check(for: .pack)
        return Button {
            selectedPlan = .pack
        } label: {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                if isSource {
                    Circle()
                        .fill(Theme.Hangs.Colors.textOnAccent)
                        .frame(width: Metrics.sourceDot, height: Metrics.sourceDot)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs / 2) {
                    Text("100 Question Pack")
                        .font(.hangsLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("One-time purchase · never expires")
                        .font(.hangsCaption)
                        .opacity(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: pack.displayPrice)
                    .font(.hangsLabel)
                    .foregroundStyle(isSelected ? Theme.Hangs.Colors.accentPrimary : Theme.Hangs.Colors.blueText)
                    .padding(.horizontal, Theme.Hangs.Spacing.sm)
                    .frame(minHeight: Metrics.pricePillHeight)
                    .background(
                        Capsule().fill(
                            isSelected ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.accentPrimarySoft
                        )
                    )
                    .fixedSize()
                planRadio(check, onCobalt: isSelected)
            }
            .foregroundStyle(isSelected ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.sm)
            .frame(minHeight: Metrics.packMinHeight)
            .background(planSurface(isSelected: isSelected))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? Self.dimmedOpacity : 1)
        // No selection change (or a second purchase) while a store operation is
        // in flight — the same rule the plan cards follow.
        .disabled(isBusy)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("paywall-plan-pack")
    }

    private enum Metrics {
        static let planMinHeight: CGFloat = 80
        static let packMinHeight: CGFloat = 72
        static let pricePillHeight: CGFloat = 30
        static let radio: CGFloat = 28
        static let ringWidth: CGFloat = 2
        static let sourceDot: CGFloat = 6
        static let offlineDisc: CGFloat = 48
    }

    // MARK: - CTA stack

    /// The one CTA, and the ONLY thing on this screen that buys anything: it
    /// purchases whatever the picker has selected, and says so. #179 finding 9
    /// reverses #129's narrating CTA — the founder read the purple pill with its
    /// own sliding indicator as a different button doing a different thing. One
    /// pink `HangsPrimaryButton`, the standard spinner via `isLoading`, which
    /// also disables it for the whole in-flight window.
    @ViewBuilder
    private var ctaButton: some View {
        if let product = picker.selectedProduct {
            // #56: the title param is LocalizedStringKey, so the interpolated
            // literal extracts as "Subscribe — %@ / month" (the displayPrice is
            // a runtime placeholder, not translatable).
            switch effectivePlan {
            case .monthly:
                purchaseCTA(title: "Subscribe — \(product.displayPrice) / month", product: product)
            case .pack:
                purchaseCTA(title: "Buy 100 Question Pack — \(product.displayPrice)", product: product)
            }
        } else {
            // Offerings not yet loaded — the load placeholder.
            HangsPrimaryButton(title: "Subscribe", isLoading: true) {}
                .accessibilityIdentifier("paywall-purchase-button")
        }
    }

    private func purchaseCTA(title: LocalizedStringKey, product: PurchasableProduct) -> some View {
        HangsPrimaryButton(title: title, isLoading: isBusy) {
            Task { await storeManager.purchase(productID: product.id) }
        }
        .accessibilityIdentifier("paywall-purchase-button")
    }

    private var paywallCTAStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            ctaButton

            HangsGhostButton(
                title: "Restore purchases",
                color: Theme.Hangs.Colors.blueText,
                font: .hangsLabel
            ) {
                Task { await storeManager.restorePurchases() }
            }
            // Fades in place while any store op is in flight (#129) — including
            // its own restore, which the blue narrating CTA reports instead.
            .opacity(isBusy ? Self.restoreFadedOpacity : 1)
            .disabled(isBusy)
            .accessibilityIdentifier("paywall-restore-button")

            // #179 finding 9: "Maybe tomorrow" is gone from both variants — the
            // ✕ in the brand row is the one way out, so there is exactly one
            // dismiss affordance instead of two competing ones.

            if let error = storeManager.purchaseError {
                Text(error)
                    .font(.hangsCaption.weight(.semibold))
                    .foregroundStyle(Theme.Hangs.Colors.error)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.purchaseError")
            }

            if storeManager.purchaseState == .pending {
                Text("Purchase is awaiting approval. You'll get access as soon as it's approved.")
                    .font(.hangsCaption.weight(.semibold))
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.pendingNotice")
            }

            if storeManager.purchaseState == .nothingToRestore {
                Text("No previous purchase found for this Apple Account.")
                    .font(.hangsCaption.weight(.semibold))
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.nothingToRestore")
            }

            // App Store review requirement: auto-renew disclosure (z8TS6 legal).
            Text("Auto-renews until cancelled. Cancel anytime in Settings.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .padding(.top, Theme.Hangs.Spacing.xxs)
                .accessibilityIdentifier("paywall.legal")

            // App Store review requirement (3.1.2): auto-renew subscriptions
            // must link the privacy policy and terms of use from the paywall.
            HStack(spacing: Theme.Hangs.Spacing.xs) {
                Link("Privacy Policy", destination: Config.privacyPolicyURL)
                    .accessibilityIdentifier("paywall.privacyPolicy")
                Text(verbatim: "·")
                Link("Terms of Use", destination: Config.termsOfUseURL)
                    .accessibilityIdentifier("paywall.termsOfUse")
            }
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Colors.muted)
        }
    }

    // MARK: - PouwN — Can't Reach The Store

    private var offlineBody: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: Theme.Hangs.Spacing.xl) {
                    Spacer(minLength: Theme.Hangs.Spacing.xl)
                    offlineIconCircle
                    offlineHeroBlock
                    Spacer(minLength: Theme.Hangs.Spacing.xl)
                    offlineCTAStack
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.md)
                .frame(minHeight: viewport.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var offlineIconCircle: some View {
        // Canvas Bg-PaywallOffline: blank cards behind a warning card, the
        // no-connection glyph on an ink disc.
        PaywallHeroDeck(fills: [Theme.Hangs.Colors.bgCard, Theme.Hangs.Colors.bgCard, Theme.Hangs.Colors.warning]) {
            Image(systemName: "wifi.slash")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.textOnAction)
                .frame(width: Metrics.offlineDisc, height: Metrics.offlineDisc)
                .background(Circle().fill(Theme.Hangs.Colors.action))
        }
        .accessibilityIdentifier("paywall.offline.icon")
    }

    private var offlineHeroBlock: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            Text("CAN'T REACH\nTHE STORE")
                .font(.hangsDisplaySM)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .hangsHeadlineFit(lines: 2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("paywall.offline.headline")

            Text("We couldn't load the upgrade right now. Check your connection and try again.")
                .font(.hangsBodyLG)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Hangs.Spacing.xs)
                .accessibilityIdentifier("paywall.offline.subtitle")
        }
    }

    private var offlineCTAStack: some View {
        HangsPrimaryButton(title: "Try Again", icon: "arrow.clockwise") {
            Task { await storeManager.loadOfferings() }
        }
        .accessibilityIdentifier("paywall-offline-retry-button")
    }
}

/// Glass disc over the success / activating card stack (canvas Bg-PaywallDone).
private struct PaywallBadge<Glyph: View>: View {
    let tint: Color
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        glyph()
            .font(.hangsHeading)
            .foregroundStyle(tint)
            .frame(width: PaywallBadgeMetrics.size, height: PaywallBadgeMetrics.size)
            .background(Circle().fill(Theme.Hangs.Colors.bgCard))
            .glassEffect(.regular, in: Circle())
    }
}

private enum PaywallBadgeMetrics {
    static let size: CGFloat = 72
}

// MARK: - Countdown Pill

private struct CountdownPill: View {
    let resetDate: Date
    @State private var timeRemaining: String = ""

    var body: some View {
        Label {
            Text(String(localized: "Free questions reset in \(timeRemaining)", comment: "Countdown pill: time until free questions reset"))
                .font(.hangsCaption.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.center)
        } icon: {
            Image(systemName: "clock")
                .font(.hangsCaption.weight(.semibold))
                .accessibilityHidden(true)
        }
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .glassEffect(.regular, in: Capsule())
            .onAppear(perform: updateCountdown)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: ResetCountdown.refreshInterval)
                    guard !Task.isCancelled else { return }
                    updateCountdown()
                }
            }
            .accessibilityIdentifier("paywall.countdownPill")
    }

    private func updateCountdown() {
        timeRemaining = ResetCountdown.text(until: resetDate, now: .now)
    }
}
