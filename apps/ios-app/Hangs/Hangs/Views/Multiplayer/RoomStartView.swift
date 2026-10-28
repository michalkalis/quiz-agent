//
//  RoomStartView.swift
//  Hangs
//
//  #212: the first screen after "Together": games on this Wi-Fi, or host one.
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
            HangsSectionLabel(text: "Games on this Wi-Fi")
            nearbyContent
            Spacer(minLength: 0)
            HangsPrimaryButton(
                title: "Host a game",
                icon: "person.2.fill",
                isLoading: viewModel.isWorking && viewModel.role == .host
            ) {
                Task { await viewModel.beginHosting() }
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("room.host")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
        .task { viewModel.startNearbySearch() }
        .onDisappear { viewModel.stopNearbySearch() }
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
        case .searching: "Looking for games on this Wi-Fi…"
        case .offWiFi: "Join the host's Wi-Fi and the game shows up here. Or scan the QR code on the host's phone with your camera."
        case .found, .failed: "No game on this Wi-Fi yet. A game started here shows up by itself. Or scan the QR code on the host's phone with your camera."
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
