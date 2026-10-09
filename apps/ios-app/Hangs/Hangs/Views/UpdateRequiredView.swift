//
//  UpdateRequiredView.swift
//  Hangs
//
//  Blocking "update the app" screen (#193 task 193.9): shown while the
//  server's minimum version for this build's channel is above the installed
//  one. Layout mirrors ErrorView (brand row, icon circle, hero, CTA at the
//  bottom). TestFlight builds open TestFlight, everything else the App Store.
//

import SwiftUI

struct UpdateRequiredView: View {
    private enum Metrics {
        static let iconCircle: CGFloat = 120
        static let iconSize: CGFloat = 48
    }

    /// App Store Connect app id of Trubbo.
    private static let appStoreId = "6762482437"

    @Environment(\.openURL) private var openURL

    let isTestFlight: Bool

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow()

            Spacer(minLength: Theme.Hangs.Spacing.xxl)

            VStack(spacing: Theme.Hangs.Spacing.xl) {
                iconCircle

                // #194 C9: plain title, no accent rule (as the error screen).
                Text("Update Trubbo")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                    .hangsHeadlineFit()
                    .accessibilityAddTraits(.isHeader)

                Text("This version is no longer supported. Install the new one to keep playing.")
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("update.message")
            }
            .padding(.horizontal, Theme.Hangs.Spacing.xl)

            Spacer()

            updateButton
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
    }

    private var iconCircle: some View {
        // #194 C9: the glyph on an ink card, like the error screen.
        Image(systemName: "arrow.down.app")
            .font(.system(size: Metrics.iconSize))
            .foregroundStyle(Theme.Hangs.Category.style(for: nil).text)
            .frame(width: Metrics.iconCircle, height: Metrics.iconCircle)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                    .fill(Theme.Hangs.Category.style(for: nil).fill)
                    .hangsShadow(Theme.Hangs.Shadow.raised)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var updateButton: some View {
        if isTestFlight {
            HangsPrimaryButton(title: "Open TestFlight", icon: "arrow.down.circle", action: openStore)
                .accessibilityIdentifier("update.open")
        } else {
            HangsPrimaryButton(title: "Open App Store", icon: "arrow.down.circle", action: openStore)
                .accessibilityIdentifier("update.open")
        }
    }

    private func openStore() {
        let link = isTestFlight
            ? "itms-beta://beta.itunes.apple.com/v1/app/\(Self.appStoreId)"
            : "https://apps.apple.com/app/id\(Self.appStoreId)"
        guard let url = URL(string: link) else { return }
        openURL(url)
    }
}

#Preview {
    UpdateRequiredView(isTestFlight: false)
}
