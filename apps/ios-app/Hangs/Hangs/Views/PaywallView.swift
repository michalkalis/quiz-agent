//
//  PaywallView.swift
//  Hangs
//
//  Two variants driven by RevenueCat offering availability (issue #93):
//    u2ySy — normal paywall ("OUT OF QUESTIONS") shown when the offering loaded.
//    PouwN — offline paywall ("CAN'T REACH THE STORE") shown when the offering
//            is unavailable after a completed load attempt.
//
//  Renders RC Offerings: subscribe (monthly primary, annual secondary) plus a
//  "buy pack" path for free users who don't want to subscribe. "Restore
//  purchase" is subscription-only — the consumable pack has no StoreKit
//  restore; its balance lives server-side in the credit ledger.
//

import SwiftUI

struct PaywallView: View {
    @ObservedObject var storeManager: StoreManager
    let limitError: QuotaLimitError?
    let onDismiss: () -> Void

    // Offline: load attempt completed but no offering returned (store unreachable).
    var isOffline: Bool {
        storeManager.hasAttemptedOfferingsLoad && storeManager.offerings == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            if isOffline {
                offlineBody
            } else {
                paywallBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
    }

    // MARK: - u2ySy — Out of Questions

    private var paywallBody: some View {
        ScrollView {
            VStack(spacing: Theme.Hangs.Spacing.xl) {
                paywallIconCircle
                    .padding(.top, Theme.Hangs.Spacing.xl)

                paywallHeroBlock

                if let resetDate = limitError?.resetDate {
                    CountdownPill(resetDate: resetDate)
                }

                featureCard

                paywallCTAStack
            }
            .padding(.horizontal, Theme.Hangs.Spacing.lg)
            .padding(.bottom, Theme.Hangs.Spacing.xl)
        }
    }

    private var paywallIconCircle: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.pinkSoft)
                .frame(width: 120, height: 120)
            Image(systemName: "infinity")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.pink)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("paywall.icon")
    }

    private var paywallHeroBlock: some View {
        VStack(spacing: 8) {
            Text("OUT OF\nQUESTIONS")
                .font(.hangsDisplayMD)
                .foregroundColor(Theme.Hangs.Colors.ink)
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

    private var limitMessage: String {
        if let limit = limitError {
            return String(localized: "You've used all \(limit.questionsLimit) free questions this month.", comment: "Paywall subtitle when the monthly free-question limit is known")
        }
        return String(localized: "You've used all your free questions this month.", comment: "Paywall subtitle when the monthly free-question limit is unknown")
    }

    private var featureCard: some View {
        VStack(spacing: 0) {
            Text("unlimited")
                .font(.hangsMono(11, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.pink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.vertical, Theme.Hangs.Spacing.sm)
                .accessibilityIdentifier("paywall.featureCard.label")

            HangsDivider()
            featureRow("Unlimited questions, every day")
            HangsDivider()
            featureRow("Never wait for the monthly reset")
            HangsDivider()
            featureRow("Cancel anytime")
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .hangsShadow(Theme.Hangs.Shadow.card)
        .accessibilityIdentifier("paywall.featureCard")
    }

    private func featureRow(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(Theme.Hangs.Colors.greenCheck)
                .accessibilityHidden(true)
            Text(text)
                .font(.hangsBody(15))
                .foregroundColor(Theme.Hangs.Colors.ink)
            Spacer()
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
    }

    private var paywallCTAStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            if let monthly = storeManager.offerings?.monthly {
                // #56: title param is LocalizedStringKey; pass the interpolated
                // literal directly so the compiler extracts "Unlock Unlimited — %@"
                // (the displayPrice is a runtime placeholder, not translatable).
                HangsPrimaryButton(
                    title: "Unlock Unlimited — \(monthly.displayPrice)/mo",
                    icon: "lock.open.fill",
                    isLoading: storeManager.isLoading
                ) {
                    Task { await storeManager.purchase(productID: monthly.id) }
                }
                .accessibilityIdentifier("paywall-purchase-button")

                if let annual = storeManager.offerings?.annual {
                    HangsGhostButton(
                        title: "Save more — \(annual.displayPrice)/yr",
                        color: Theme.Hangs.Colors.blue
                    ) {
                        Task { await storeManager.purchase(productID: annual.id) }
                    }
                    .accessibilityIdentifier("paywall-purchase-annual-button")
                }
            } else {
                HangsPrimaryButton(
                    title: "Unlock Unlimited",
                    icon: "lock.open.fill",
                    isLoading: true
                ) {}
                    .accessibilityIdentifier("paywall-purchase-button")
            }

            if let pack = storeManager.offerings?.pack {
                HangsGhostButton(
                    title: "Buy +100 Questions — \(pack.displayPrice)",
                    color: Theme.Hangs.Colors.muted
                ) {
                    Task { await storeManager.purchase(productID: pack.id) }
                }
                .accessibilityIdentifier("paywall-purchase-pack-button")
            }

            HangsGhostButton(title: "Restore purchase", color: Theme.Hangs.Colors.blue) {
                Task { await storeManager.restorePurchases() }
            }
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
            }
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

// MARK: - Countdown Pill

private struct CountdownPill: View {
    let resetDate: Date
    @State private var timeRemaining: String = ""
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)
            Text(String(localized: "Free questions reset in \(timeRemaining)", comment: "Countdown pill: time until free questions reset"))
                .font(.hangsBody(13, weight: .medium))
        }
        .foregroundColor(Theme.Hangs.Colors.muted)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
        .overlay(Capsule().stroke(Theme.Hangs.Colors.subtleBorder, lineWidth: 1))
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
