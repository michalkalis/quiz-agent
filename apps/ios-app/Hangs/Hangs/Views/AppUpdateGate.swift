//
//  AppUpdateGate.swift
//  Hangs
//
//  Puts `UpdateRequiredView` over the whole app while an update is required
//  (#193 task 193.9). The app stays mounted underneath (hidden from
//  accessibility) so lifting the minimum on the server returns the player to
//  where they were instead of rebuilding the navigation tree. #214: the
//  maintenance screen sits in the same place, below the forced update.
//

import SwiftUI

struct AppUpdateGate<Content: View>: View {
    @ObservedObject var store: AppConfigStore
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            content
                .accessibilityHidden(store.updateRequired || store.maintenance)
            if store.updateRequired {
                UpdateRequiredView(isTestFlight: store.isTestFlight)
                    .transition(.opacity)
            } else if store.maintenance {
                MaintenanceView(store: store)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: store.updateRequired)
        .animation(.easeInOut, value: store.maintenance)
    }
}
