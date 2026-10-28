//
//  MaintenanceView.swift
//  Hangs
//
//  Full-screen maintenance message (#214): shown over the whole app while the
//  server's maintenance switch is on. Layout mirrors UpdateRequiredView. No
//  button: the player may be driving, so the store checks the server again on
//  its own and the app continues as soon as the switch is off.
//

import SwiftUI

struct MaintenanceView: View {
    private enum Metrics {
        static let iconCircle: CGFloat = 120
        static let iconSize: CGFloat = 48
    }

    @ObservedObject var store: AppConfigStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: Theme.Hangs.Spacing.xxl)

            VStack(spacing: Theme.Hangs.Spacing.xl) {
                iconCircle

                Text("Back in a moment")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                    .hangsHeadlineFit()
                    .accessibilityAddTraits(.isHeader)

                message
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("maintenance.message")
            }
            .padding(.horizontal, Theme.Hangs.Spacing.xl)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .task { await store.recheckUntilMaintenanceEnds() }
    }

    private var message: Text {
        if let text = store.maintenanceMessage {
            Text(verbatim: text)
        } else {
            Text("Trubbo is under maintenance. It picks up on its own as soon as we're done.")
        }
    }

    private var iconCircle: some View {
        Image(systemName: "wrench.and.screwdriver")
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
}

#Preview {
    MaintenanceView(store: AppConfigStore(fetch: {
        RemoteAppConfig(minVersionAppStore: nil, minVersionTestflight: nil, ordersEnabled: true, notice: nil, maintenanceEnabled: true)
    }))
}
