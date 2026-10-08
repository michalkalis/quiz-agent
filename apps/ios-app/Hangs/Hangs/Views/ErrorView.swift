//
//  ErrorView.swift
//  Hangs
//
//  The quiz error screen (Fwafe frame). Moved out of ContentView in #194 A1.
//

import SwiftUI

/// Error screen — Fwafe frame. Bound to AppErrorModel (52.7 mapping).
/// Red icon circle + "OOPS" Anton hero + error-accent line + model title/description + CTA stack.
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let model: AppErrorModel

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            Spacer(minLength: 40)

            VStack(spacing: Theme.Hangs.Spacing.xl) {
                errorIconCircle

                heroBlock

                Text(model.description)
                    .font(.hangsBody(15))
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 28)
                    .accessibilityLabel(String(localized: "Error: \(model.title). \(model.description)", comment: "Accessibility label for the error screen: error title and description"))
                    .accessibilityIdentifier("error.description")

                #if DEBUG
                    if let detail = viewModel.lastErrorDebugInfo {
                        DebugErrorDetailsView(detail: detail)
                            .padding(.horizontal, 20)
                    }
                #endif
            }

            Spacer()

            ctaStack
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .accessibilityIdentifier("error.root")
    }

    private var errorIconCircle: some View {
        ZStack {
            Circle()
                .fill(Theme.Hangs.Colors.error.opacity(0.12))
                .frame(width: 120, height: 120)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(Theme.Hangs.Colors.error)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("error.icon")
    }

    private var heroBlock: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            Text("OOPS")
                .font(.hangsDisplayMD)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Capsule()
                .fill(Theme.Hangs.Colors.error)
                .frame(width: 40, height: 3)
                .accessibilityHidden(true)

            Text(model.title)
                .font(.hangsBody(17, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("error.title")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: 10) {
            switch model.retryAction {
            case .retryOperation:
                HangsPrimaryButton(title: "Try Again", icon: "arrow.clockwise") {
                    viewModel.retryFromErrorScreen()
                }
                .accessibilityIdentifier("error.retry")

                HangsSecondaryButton(title: "Go Home", icon: "house.fill", height: 56) {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("error.home")

            case .goHome:
                HangsPrimaryButton(title: "Go Home", icon: "house.fill") {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("error.home")

            case .dismiss:
                HangsSecondaryButton(title: "Dismiss", icon: "xmark", height: 56) {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("error.dismiss")
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .padding(.bottom, Theme.Hangs.Spacing.lg)
    }
}
