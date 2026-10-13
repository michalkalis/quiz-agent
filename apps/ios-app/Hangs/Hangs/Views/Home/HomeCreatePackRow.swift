//
//  HomeCreatePackRow.swift
//  Hangs
//
//  Home entry to the custom-pack order sheet (TestFlight feedback 2026-10-09:
//  ordering was reachable only from Settings): the last row of the "my packs"
//  card (Home redesign, founder pick 2026-10-13). Always shown, even with no
//  packs yet; while orders are paused on the server (#193 task 193.9) it stays
//  visible but disabled with the reason, like the Settings row.
//

import SwiftUI

struct HomeCreatePackRow: View {
    @ObservedObject var appConfig: AppConfigStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                // Centred in the swatch column, so the label lines up with
                // the pack titles above it.
                Image(systemName: "plus")
                    .font(.hangsLabel)
                    .frame(width: HomePackRow.Metrics.swatchSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs / 2) {
                    Text("Create your own pack")
                        .font(.hangsLabel)
                    if !appConfig.ordersEnabled {
                        Text("Ordering is paused for now.")
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Home links are blue; paused ordering reads muted.
            .foregroundStyle(appConfig.ordersEnabled ? Theme.Hangs.Colors.blue : Theme.Hangs.Colors.muted)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: HomePackRow.Metrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!appConfig.ordersEnabled)
        .accessibilityIdentifier("home.createPack")
    }
}

#if DEBUG
    #Preview {
        HangsCard(padding: .init(top: 0, leading: 16, bottom: 0, trailing: 16)) {
            HomeCreatePackRow(appConfig: AppConfigStore(fetch: { .permissive }), action: {})
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
