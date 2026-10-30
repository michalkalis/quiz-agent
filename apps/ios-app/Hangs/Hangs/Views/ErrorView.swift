//
//  ErrorView.swift
//  Hangs
//
//  The quiz error screen (Fwafe frame). Moved out of ContentView in #194 A1.
//

import SwiftUI

/// Error screen — Fwafe frame. Bound to AppErrorModel (52.7 mapping).
/// #194 C9: a face-down card with the warning glyph, "OOPS" overline, the
/// model's title as headline, its description, and the CTA stack for its action.
struct ErrorView: View {
    @ObservedObject var viewModel: QuizViewModel
    let model: AppErrorModel

    var body: some View {
        VStack(spacing: 0) {
            // #194 C9 (canvas Bg-Offline): a face-down card carries the glyph;
            // the error's own title is the headline. Scrolls once large text
            // outgrows the screen, buttons stay pinned. #198: no logo past Home,
            // and the card is striped cobalt (retry) or mandarin, never ink.
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

    private var isRetry: Bool { model.retryAction == .retryOperation }

    private var errorIconCircle: some View {
        let category = Theme.Hangs.Category.self
        let style = isRetry ? category.errorOffline : category.errorOther
        let stripe = isRetry ? category.errorOfflineStripe : category.errorOtherStripe
        return ErrorCardStripes(stripe: stripe)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous))
            .padding(Theme.Hangs.Spacing.sm)
            .overlay {
                Image(systemName: isRetry ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Category.chipText)
                    .frame(width: Metrics.disc, height: Metrics.disc)
                    .background(Circle().fill(Theme.Hangs.Category.chipFill))
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
                .accessibilityLabel(String(localized: "Error: \(model.title). \(model.description)", bundle: .interface, locale: .interface, comment: "Accessibility label for the error screen: error title and description"))
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

/// Diagonal stripes of the error card's inner panel (canvas Bg-Offline).
private struct ErrorCardStripes: View {
    let stripe: Color

    private enum Metrics {
        static let width: CGFloat = 10
    }

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += Metrics.width * 2
            }
            context.stroke(path, with: .color(stripe), lineWidth: Metrics.width / 1.4)
        }
    }
}
