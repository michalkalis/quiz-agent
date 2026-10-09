//
//  ErrorView.swift
//  Hangs
//
//  The quiz error screen (Fwafe frame). Moved out of ContentView in #194 A1.
//

import SwiftUI

/// Error screen — Fwafe frame. Bound to AppErrorModel (52.7 mapping).
/// #194 C9: ink card with the warning glyph, "OOPS" overline, the model's
/// title as headline, its description, and the CTA stack for its action.
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let model: AppErrorModel

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            // #194 C9 (canvas Bg-Offline): a face-down ink card carries the
            // glyph; the error's own title is the headline. Scrolls once large
            // text outgrows the screen, buttons stay pinned.
            ScrollView {
                VStack(spacing: Theme.Hangs.Spacing.xl) {
                    Spacer(minLength: Theme.Hangs.Spacing.md)

                    errorIconCircle

                    heroBlock

                    #if DEBUG
                        if let detail = viewModel.lastErrorDebugInfo {
                            DebugErrorDetailsView(detail: detail)
                                .padding(.horizontal, Theme.Hangs.Spacing.lg)
                        }
                    #endif
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center)

            ctaStack
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .accessibilityIdentifier("error.root")
    }

    private var errorIconCircle: some View {
        let style = Theme.Hangs.Category.style(for: nil)
        return RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
            .fill(style.text.opacity(0.08))
            .padding(Theme.Hangs.Spacing.sm)
            .overlay {
                Image(systemName: "exclamationmark.triangle")
                    .font(.hangsTitle)
                    .foregroundStyle(style.text)
                    .frame(width: Metrics.disc, height: Metrics.disc)
                    .background(Circle().fill(style.fill))
                    .overlay(Circle().strokeBorder(style.text.opacity(0.2)))
            }
            .frame(width: Metrics.card.width, height: Metrics.card.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                    .fill(style.fill)
                    .hangsShadow(Theme.Hangs.Shadow.raised)
            )
            .accessibilityHidden(true)
            .accessibilityIdentifier("error.icon")
    }

    private var heroBlock: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            Text("OOPS")
                .font(.hangsOverline)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .accessibilityAddTraits(.isHeader)

            Text(model.title)
                .font(.hangsTitle)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("error.title")

            Text(model.description)
                .font(.hangsBodyLG)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Hangs.Spacing.sm)
                .accessibilityLabel(String(localized: "Error: \(model.title). \(model.description)", comment: "Accessibility label for the error screen: error title and description"))
                .accessibilityIdentifier("error.description")
        }
    }

    private enum Metrics {
        /// Canvas card (200 × 268) and the glyph disc on it.
        static let card = CGSize(width: 160, height: 214)
        static let disc: CGFloat = 76
    }

    @ViewBuilder
    private var ctaStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
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
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.top, Theme.Hangs.Spacing.sm)
        .padding(.bottom, Theme.Hangs.Spacing.sm)
    }
}
