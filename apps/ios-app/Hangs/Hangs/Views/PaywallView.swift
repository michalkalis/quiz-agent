//
//  PaywallView.swift
//  Hangs
//
//  Shown when daily free question limit is reached.
//  Offers upgrade to unlimited or dismiss until tomorrow.
//

import StoreKit
import SwiftUI

struct PaywallView: View {
    @ObservedObject var storeManager: StoreManager
    let limitError: DailyLimitError?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            // MARK: - Icon
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Theme.Colors.accentPrimary, Theme.Colors.accentSecondary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .accessibilityHidden(true)

            // MARK: - Title
            VStack(spacing: Theme.Spacing.sm) {
                Text("You're on a Roll!")
                    .font(.displayXL)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(limitMessage)
                    .font(.textMD)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // MARK: - Reset countdown
            if let resetDate = limitError?.resetDate {
                CountdownToReset(resetDate: resetDate)
            }

            Spacer()

            // MARK: - Actions
            VStack(spacing: Theme.Spacing.sm) {
                // Purchase button
                if let product = storeManager.product {
                    PrimaryButton(
                        title: "Unlock Unlimited — \(product.displayPrice)",
                        icon: "lock.open.fill",
                        isLoading: storeManager.isLoading
                    ) {
                        Task { await storeManager.purchase() }
                    }
                } else {
                    PrimaryButton(
                        title: "Unlock Unlimited",
                        icon: "lock.open.fill",
                        isLoading: true
                    ) {}
                }

                // Restore purchases
                Button("Restore Purchase") {
                    Task { await storeManager.restorePurchases() }
                }
                .font(.textSM)
                .foregroundColor(Theme.Colors.accentPrimary)

                // Dismiss
                Button("Come Back Tomorrow") {
                    onDismiss()
                }
                .font(.textSM)
                .foregroundColor(Theme.Colors.textSecondary)
                .padding(.top, Theme.Spacing.xs)
            }
            .padding(.horizontal, Theme.Spacing.lg)

            // Error message
            if let error = storeManager.purchaseError {
                Text(error)
                    .font(.textSM)
                    .foregroundColor(Theme.Colors.error)
                    .multilineTextAlignment(.center)
            }

            Spacer()
                .frame(height: Theme.Spacing.xl)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.bgPrimary)
    }

    private var limitMessage: String {
        if let limit = limitError {
            return "You've used all \(limit.questionsLimit) free questions today. Unlock unlimited to keep playing!"
        }
        return "You've used all your free questions today. Unlock unlimited to keep playing!"
    }
}

// MARK: - Countdown to Reset

private struct CountdownToReset: View {
    let resetDate: Date
    @State private var timeRemaining: String = ""
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "clock")
                .font(.textSM)
                .accessibilityHidden(true)
            Text("Free questions reset in \(timeRemaining)")
                .font(.textSM)
        }
        .foregroundColor(Theme.Colors.textTertiary)
        .onAppear { startTimer() }
        .onDisappear { timer?.invalidate() }
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
            timeRemaining = "now"
            return
        }
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            timeRemaining = "\(hours)h \(minutes)m"
        } else {
            timeRemaining = "\(minutes)m"
        }
    }
}

// MARK: - Helper extension

private extension DailyLimitError {
    var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt) ?? ISO8601DateFormatter().date(from: resetsAt)
    }
}
