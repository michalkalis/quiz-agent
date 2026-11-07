//
//  RoomLobbyHostView.swift
//  Hangs
//
//  #212: the host's room before the start: QR code, invite link, players.
//  #224 (A+B): the QR sits beside the invite text and the rules fold into one
//  row that opens the rules sheet, so up to ~5 players fit without scrolling.
//

import SwiftUI

struct RoomLobbyHostView: View {
    @ObservedObject var viewModel: RoomViewModel
    @State private var playerToRemove: RoomState.Player?
    @State private var showingRules = false

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                    inviteCard
                    HStack {
                        HangsSectionLabel(text: "Players")
                        Spacer()
                        Text(verbatim: "\(viewModel.players.count)")
                            .font(.hangsMonoLabel)
                            .foregroundStyle(Theme.Hangs.Colors.sectionLabel)
                    }
                    playerList
                    rulesRow
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            HangsPrimaryButton(title: "Start the game", icon: "play.fill", isLoading: viewModel.isWorking) {
                Task { await viewModel.startGame() }
            }
            .disabled(viewModel.isWorking || viewModel.state == nil)
            .accessibilityIdentifier("room.start")
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
        .sheet(isPresented: $showingRules) {
            RoomRulesSheet(viewModel: viewModel)
        }
        .confirmationDialog(
            "Remove this player from the game?",
            isPresented: Binding(get: { playerToRemove != nil }, set: { if !$0 { playerToRemove = nil } }),
            titleVisibility: .visible,
            presenting: playerToRemove
        ) { player in
            Button("Remove", role: .destructive) {
                Task { await viewModel.remove(player) }
            }
        }
    }

    private var inviteCard: some View {
        HangsCard {
            VStack(spacing: Theme.Hangs.Spacing.sm) {
                HStack(spacing: Theme.Hangs.Spacing.md) {
                    if let created = viewModel.created, let image = QRCodeImage.make(created.qrURL.absoluteString) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: Metrics.qrSide, height: Metrics.qrSide)
                            .accessibilityLabel(Text("QR code to join the game"))
                            .accessibilityIdentifier("room.qr")
                    } else {
                        ProgressView()
                            .frame(width: Metrics.qrSide, height: Metrics.qrSide)
                    }
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                        Text("Scan to join")
                            .font(.hangsHeading)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                        Text("Players on the same Wi-Fi also find the game in Trubbo under Together.")
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let created = viewModel.created {
                    // a11y-id: call-site — ShareLink takes its identifier below
                    ShareLink(item: created.inviteURL, message: Text("Join my game in Trubbo")) {
                        Label("Send the link", systemImage: "square.and.arrow.up")
                            .font(.hangsButton)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                            .frame(maxWidth: .infinity, minHeight: Metrics.shareHeight)
                            .background(Capsule().fill(Theme.Hangs.Colors.bgInset))
                    }
                    .accessibilityIdentifier("room.share")
                    Text("The link also works for friends in another city.")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity)
        }
    }

    private var playerList: some View {
        HangsCard {
            VStack(spacing: 0) {
                ForEach(viewModel.players) { player in
                    playerRow(player)
                    if player.id != viewModel.players.last?.id { HangsDivider() }
                }
            }
        }
    }

    private func playerRow(_ player: RoomState.Player) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            RoomPlayerAvatar(name: player.displayName, color: player.color)
            Text(verbatim: player.displayName)
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if player.isHost {
                Text("you · host")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            } else {
                Button {
                    playerToRemove = player
                } label: {
                    Image(systemName: "xmark")
                        .font(.hangsBody(Metrics.removeIcon, weight: .semibold))
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .frame(width: Metrics.removeSide, height: Metrics.removeSide)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(player.displayName)"))
                .accessibilityIdentifier("room.player.remove.\(player.participantId)")
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .frame(minHeight: Metrics.rowHeight)
        .accessibilityIdentifier("room.player.\(player.participantId)")
    }

    /// #224 (A): the rules in one row; the sheet changes them.
    private var rulesRow: some View {
        HangsCard {
            Button {
                showingRules = true
            } label: {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                        Text("Game rules")
                            .font(.hangsLabel)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                        rulesSummary
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .accessibilityIdentifier("room.lobby.summary")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.hangsCaption.weight(.semibold))
                        .foregroundStyle(Theme.Hangs.Colors.mutedFaint)
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.vertical, Theme.Hangs.Spacing.sm)
                .frame(minHeight: Metrics.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("room.lobby.rules")
        }
    }

    /// "10 questions · Medium · Answers at the end · 30 s": what everyone
    /// plays (the difficulty reads as on Home) and the room's rules.
    private var rulesSummary: Text {
        let settings = viewModel.settings
        let rules = [
            viewModel.solo.difficultyDisplayName(),
            settings.revealMode.displayName,
            MultiplayerSettings.secondsDisplay(settings.thinkingSeconds),
        ]
        return Text("\(viewModel.solo.numberOfQuestions) questions")
            + Text(verbatim: rules.map { " · \($0)" }.joined())
    }

    private enum Metrics {
        /// #224 (B): beside the text; still scans from a phone across a table.
        static let qrSide: CGFloat = 128
        static let shareHeight: CGFloat = 44
        static let removeSide: CGFloat = 44
        static let removeIcon: CGFloat = 14
        static let rowHeight: CGFloat = 56
    }
}
