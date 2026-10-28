//
//  HomeTogetherButton.swift
//  Hangs
//
//  #212 (variant A, founder 2026-10-28): "Together" next to Start opens a game
//  together. Shown only while the server's multiplayer switch is on.
//

import SwiftUI

struct HomeTogetherButton: View {
    @ObservedObject var store: AppConfigStore
    let action: () -> Void

    var body: some View {
        if store.multiplayerEnabled {
            Button(action: action) {
                VStack(spacing: Theme.Hangs.Spacing.xxs) {
                    Image(systemName: "person.2")
                        .font(.hangsBody(Metrics.icon, weight: .semibold))
                    Text("Together")
                        .font(.hangsMonoMini)
                        .textCase(.uppercase)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .frame(width: Metrics.width, height: Metrics.height)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.together")
        }
    }

    private enum Metrics {
        /// Canvas variant A: a compact twin beside the full-width Start.
        static let width: CGFloat = 96
        static let height: CGFloat = 56
        static let icon: CGFloat = 18
    }
}
