//
//  CreatePackRow.swift
//  Hangs
//
//  Settings "Create a pack" row (#138). While orders are paused on the
//  server (#193 task 193.9) it stays visible but disabled, with the reason
//  under the label, so the feature does not silently disappear.
//

import SwiftUI

struct CreatePackRow: View {
    @ObservedObject var appConfig: AppConfigStore
    let action: () -> Void

    var body: some View {
        // #138: a modal trigger, not a push, hence no chevron.
        // a11y-id: call-site — SettingsView tags it `packs.createPack`
        HangsConfigRow(
            label: "Create a pack",
            value: "",
            subtitle: appConfig.ordersEnabled ? nil : "Ordering is paused for now.",
            valueColor: Theme.Hangs.Colors.muted,
            showsChevron: false,
            action: action
        )
        .disabled(!appConfig.ordersEnabled)
    }
}
