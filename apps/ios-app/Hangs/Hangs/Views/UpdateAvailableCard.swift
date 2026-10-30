//
//  UpdateAvailableCard.swift
//  Hangs
//
//  Optional "new version" card on Home (#214): shown while the server's
//  recommended version for this build's channel is above the installed one.
//  Dismissible; stays hidden until the server recommends a newer version.
//  Renders nothing otherwise. Styled like AppNoticeBanner.
//

import SwiftUI

struct UpdateAvailableCard: View {
    private enum Metrics {
        static let iconSize: CGFloat = 15
        static let tapTarget: CGFloat = 44
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: AppConfigStore

    var body: some View {
        if store.updateRecommended {
            HangsCard(padding: EdgeInsets(
                top: Theme.Hangs.Spacing.xxs,
                leading: Theme.Hangs.Spacing.md,
                bottom: Theme.Hangs.Spacing.xxs,
                trailing: Theme.Hangs.Spacing.xxs
            )) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    Image(systemName: "arrow.down.app")
                        .font(.system(size: Metrics.iconSize, weight: .semibold))
                        .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
                        .accessibilityHidden(true)
                    // Large text: the button goes under the message so neither breaks mid-word.
                    messageLayout {
                        Text("A new version of Trubbo is ready.")
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Hangs.Spacing.sm)
                            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 0 : Theme.Hangs.Spacing.sm)
                        Button(action: openStore) {
                            Text("Update", comment: "Home card button: open the App Store or TestFlight to install the new version")
                                .font(.hangsBody.weight(.semibold))
                                .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
                                .lineLimit(1)
                                .fixedSize()
                                .frame(minHeight: Metrics.tapTarget)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home.update.open")
                    }
                    Button(action: store.dismissUpdate) {
                        Image(systemName: "xmark")
                            .font(.system(size: Metrics.iconSize, weight: .semibold))
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss", bundle: .interface, locale: .interface, comment: "Accessibility label: hide the notice on Home"))
                    .accessibilityIdentifier("home.update.dismiss")
                }
            }
        }
    }

    private var messageLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: Theme.Hangs.Spacing.sm))
    }

    private func openStore() {
        guard let url = UpdateRequiredView.storeURL(isTestFlight: store.isTestFlight) else { return }
        openURL(url)
    }
}
