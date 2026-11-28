//
//  RoomStartView.swift
//  Hangs
//
//  #212: the first screen after "Together": how it works, games nearby, or host one.
//

import SwiftUI

struct RoomStartView: View {
    @ObservedObject var viewModel: RoomViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            HangsHeroBlock(
                title: "Play together",
                subtitle: "Everyone answers on their own phone.",
                titleFont: .hangsTitle
            )
            howItWorks
            nearbyContent
            Spacer(minLength: 0)
            HangsPrimaryButton(
                title: "Host a game",
                icon: "person.2.fill",
                isLoading: viewModel.isWorking && viewModel.role == .host,
                fillsWidth: false,
                contentInset: Theme.Hangs.Spacing.xxl * 2
            ) {
                Task { await viewModel.beginHosting() }
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("room.host")
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
        .task { viewModel.startNearbySearch() }
        .onDisappear { viewModel.stopNearbySearch() }
    }

    /// #252 (founder 2026-11-27): numbered steps instead of a "Games on this
    /// Wi-Fi" label that read awkwardly, above all in Ukrainian.
    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "How it works")
            HangsCard {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    step(1, "Everyone connects to the same Wi-Fi.")
                    step(2, "Everyone opens Trubbo on their phone and taps Together.")
                    step(3, "One player taps Host a game. The others tap Join below, or scan the QR code on the host's phone.")
                    step(4, "The host starts the game and moves it on after each question.")
                }
                .padding(Theme.Hangs.Spacing.md)
            }
            .accessibilityIdentifier("room.howItWorks")
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.sm) {
            Text(verbatim: "\(number).")
                .font(.hangsLabel.monospacedDigit())
                .foregroundStyle(Theme.Hangs.Colors.muted)
            Text(text)
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var nearbyContent: some View {
        if viewModel.nearby.isEmpty {
            HangsCard {
                HStack(alignment: .top, spacing: Theme.Hangs.Spacing.sm) {
                    if viewModel.nearbyStatus == .searching {
                        ProgressView()
                    }
                    Text(emptyText)
                        .font(.hangsBody)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Hangs.Spacing.md)
            }
            .accessibilityIdentifier("room.nearby.empty")
        } else {
            HangsCard {
                VStack(spacing: 0) {
                    ForEach(viewModel.nearby) { room in
                        nearbyRow(room)
                        if room.id != viewModel.nearby.last?.id { HangsDivider() }
                    }
                }
            }
        }
    }

    private var emptyText: LocalizedStringKey {
        switch viewModel.nearbyStatus {
        case .searching: "Looking for games…"
        case .offWiFi: "You're not on Wi-Fi. Connect to the host's Wi-Fi and the game shows up here."
        case .found, .failed: "No game here yet. The host's game shows up here by itself."
        }
    }

    private func nearbyRow(_ room: NearbyRoom) -> some View {
        Button {
            Task { await viewModel.join(.nearby(room)) }
        } label: {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                RoomPlayerAvatar(name: room.hostName, color: room.hostColor)
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text(verbatim: room.hostName)
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                    Text("\(room.playerCount) players")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Join")
                    .font(.hangsButton)
                    .foregroundStyle(Theme.Hangs.Colors.blueText)
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .frame(minHeight: 60)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier("room.nearby.\(room.roomId)")
    }
}
