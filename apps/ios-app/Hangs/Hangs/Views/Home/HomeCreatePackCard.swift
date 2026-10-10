//
//  HomeCreatePackCard.swift
//  Hangs
//
//  Home entry to the custom-pack order sheet (TestFlight feedback 2026-10-09:
//  ordering was reachable only from Settings). Always shown, even with no
//  packs yet; while orders are paused on the server (#193 task 193.9) it stays
//  visible but disabled with the reason, like the Settings row.
//

import SwiftUI

struct HomeCreatePackCard: View {
    @ObservedObject var appConfig: AppConfigStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.hangsLabel)
                    .foregroundStyle(appConfig.ordersEnabled ? Theme.Hangs.Colors.actionText : Theme.Hangs.Colors.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text("Create your own pack")
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                    if !appConfig.ordersEnabled {
                        Text("Ordering is paused for now.")
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Metrics.minHeight)
            .contentShape(.rect)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cta, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!appConfig.ordersEnabled)
        .accessibilityIdentifier("home.createPack")
    }

    private enum Metrics {
        /// Same height as the Home setting pills, so the glass controls line up.
        static let minHeight: CGFloat = 56
    }
}

#if DEBUG
    #Preview {
        HomeCreatePackCard(appConfig: AppConfigStore(fetch: { .permissive }), action: {})
            .padding(16)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
