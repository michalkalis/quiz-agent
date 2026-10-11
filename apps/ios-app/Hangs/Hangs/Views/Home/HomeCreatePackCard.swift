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
            HangsCard(padding: EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18)) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    Image(systemName: "plus")
                        .font(.hangsBody(15, weight: .semibold))
                        .foregroundColor(appConfig.ordersEnabled ? Theme.Hangs.Colors.ink : Theme.Hangs.Colors.muted)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Create your own pack")
                            .font(.hangsBody(15, weight: .semibold))
                            .foregroundColor(Theme.Hangs.Colors.ink)
                        if !appConfig.ordersEnabled {
                            Text("Ordering is paused for now.")
                                .font(.hangsBody(12))
                                .foregroundColor(Theme.Hangs.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: Metrics.minHeight)
            }
            .padding(.horizontal, Theme.Hangs.Spacing.lg)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!appConfig.ordersEnabled)
        .accessibilityIdentifier("home.createPack")
    }

    private enum Metrics {
        /// Keeps the tap target comfortable.
        static let minHeight: CGFloat = 28
    }
}

#if DEBUG
    #Preview {
        HomeCreatePackCard(appConfig: AppConfigStore(fetch: { .permissive }), action: {})
            .padding(16)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
