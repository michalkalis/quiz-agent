//
//  DailyCrewCard.swift
//  Hangs
//
//  #239 — the daily crew on the daily round end: everyone the player swapped
//  a daily link with, by rarity points this week (founder 2026-11-18,
//  variant B). Nothing to set up: with no crew yet, one line says how a crew
//  forms (only when this phone can send the link). A long press on a person
//  offers to remove them; both then stop seeing each other.
//

import SwiftUI

struct DailyCrewCard: View {
    @ObservedObject var model: DailyCrewViewModel
    /// The player's own row: the name they use in the app.
    let playerName: String
    /// With no crew yet, explain how one forms (only when Share sends a link).
    let canInvite: Bool

    @State private var pendingRemoval: DailyCrewMember?

    private static let padding = EdgeInsets(
        top: Theme.Hangs.Spacing.sm, leading: Theme.Hangs.Spacing.md,
        bottom: Theme.Hangs.Spacing.sm, trailing: Theme.Hangs.Spacing.md
    )

    var body: some View {
        if let crew = model.crew {
            if crew.members.isEmpty {
                if canInvite { invite }
            } else {
                table(crew.members)
            }
        }
    }

    private var invite: some View {
        HangsCard(padding: Self.padding) {
            Label {
                Text("Send the challenge to a friend. Whoever plays it is in your crew table all week.")
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(Theme.Hangs.Colors.blue)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("daily.crew.invite")
    }

    private func table(_ members: [DailyCrewMember]) -> some View {
        HangsCard(padding: Self.padding) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                HangsSectionLabel(text: "your crew this week")
                ForEach(members) { member in
                    row(member)
                }
                Text("A right answer few people knew scores more, up to 100 points.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Hangs.Spacing.xxs)
                if model.removeFailed {
                    Text("Could not remove. Try again.")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .accessibilityIdentifier("daily.crew.removeFailed")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("daily.crew")
        .confirmationDialog(
            "Remove from your crew?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { member in
            Button("Remove", role: .destructive) {
                Task { await model.remove(member) }
            }
            .accessibilityIdentifier("daily.crew.remove.confirm")
        } message: { _ in
            Text("You will no longer see each other in the table.")
        }
    }

    @ViewBuilder
    private func row(_ member: DailyCrewMember) -> some View {
        let content = HStack(spacing: Theme.Hangs.Spacing.sm) {
            Text(verbatim: "\(member.place).")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .monospacedDigit()
                .frame(minWidth: 24, alignment: .leading)
            Group {
                if member.isYou {
                    Text("\(playerName) (you)")
                } else {
                    Text(verbatim: member.name ?? "")
                }
            }
            .font(member.isYou ? .hangsLabel.weight(.semibold) : .hangsLabel)
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .lineLimit(1)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            Text(verbatim: "\(member.points)")
                .font(.hangsLabel.weight(.semibold))
                .foregroundStyle(member.isYou ? Theme.Hangs.Colors.blue : Theme.Hangs.Colors.ink)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(member))
        .accessibilityIdentifier(member.isYou ? "daily.crew.you" : "daily.crew.member")

        if member.isYou {
            content
        } else {
            content
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Remove from crew", systemImage: "person.badge.minus", role: .destructive) {
                        pendingRemoval = member
                    }
                    .accessibilityIdentifier("daily.crew.menu.remove")
                }
                .accessibilityAction(named: Text("Remove from crew")) { pendingRemoval = member }
        }
    }

    private func accessibilityLabel(_ member: DailyCrewMember) -> String {
        let name = member.isYou ? playerName : (member.name ?? "")
        return String(
            localized: "\(member.place). \(name), points: \(member.points)",
            bundle: .interface, locale: .interface,
            comment: "#239 accessibility label of a crew table row: place, name, points this week"
        )
    }
}
