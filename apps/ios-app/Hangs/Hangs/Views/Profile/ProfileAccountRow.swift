//
//  ProfileAccountRow.swift
//  Hangs
//
//  #213.4: who is playing, at the top of the Profile. The whole row opens
//  Settings, where the account (sign-in, export, deletion) lives.
//

import SwiftUI

struct ProfileAccountRow: View {
    let account: ProfileViewModel.Account
    /// The plan, nil until /usage has loaded.
    let isPlus: Bool?

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            avatar
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                name
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                if let isPlus {
                    plan(isPlus)
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                }
                if !account.isSignedIn {
                    Text("Sign in to keep your stats")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.hangsCaption.weight(.semibold))
                .foregroundStyle(Theme.Hangs.Colors.mutedFaint)
                .accessibilityHidden(true)
        }
        .padding(Theme.Hangs.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .contentShape(.rect)
    }

    private var name: Text {
        if let name = account.name {
            Text(verbatim: name)
        } else {
            Text("Player")
        }
    }

    private func plan(_ isPlus: Bool) -> Text {
        isPlus ? Text(verbatim: "Trubbo Plus") : Text("Free plan")
    }

    private var avatar: some View {
        let style = Theme.Hangs.Category.style(for: "history")
        return Circle()
            .fill(style.fill)
            .frame(width: Metrics.avatar, height: Metrics.avatar)
            .overlay {
                if let initial = account.name?.first {
                    Text(verbatim: String(initial).uppercased())
                        .font(.hangsHeading)
                        .foregroundStyle(style.text)
                } else {
                    Image(systemName: "person.fill")
                        .font(.hangsBodyLG)
                        .foregroundStyle(style.text)
                }
            }
            .accessibilityHidden(true)
    }

    private enum Metrics {
        static let avatar: CGFloat = 44
    }
}
