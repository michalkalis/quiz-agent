//
//  RoomGuestRulesCard.swift
//  Hangs
//
//  #213.8: a guest sees the host's rules in the lobby, read-only. A rule the
//  room doesn't say (an older server) is left out.
//

import SwiftUI

struct RoomGuestRulesCard: View {
    let revealMode: RoomState.RevealMode?
    let thinkingSeconds: Int?
    let readsAloud: Bool?

    var body: some View {
        if revealMode != nil || thinkingSeconds != nil || readsAloud == true {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                HangsSectionLabel(text: "Rules from the host")
                HangsCard {
                    VStack(spacing: 0) {
                        if let revealMode {
                            row("When to show answers", value: revealMode.displayName, id: "reveal")
                        }
                        if let thinkingSeconds {
                            if revealMode != nil { HangsDivider() }
                            row("Answer time", value: MultiplayerSettings.secondsDisplay(thinkingSeconds), id: "time")
                        }
                        if readsAloud == true {
                            if revealMode != nil || thinkingSeconds != nil { HangsDivider() }
                            row("Questions read by", value: hostPhone, id: "readsAloud")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("room.rules.guest")
        }
    }

    private var hostPhone: String {
        String(localized: "the host's phone", bundle: .interface, locale: .interface, comment: "Hra spolu: who reads the questions aloud (Questions read by: the host's phone)")
    }

    private func row(_ label: LocalizedStringKey, value: String, id: String) -> some View {
        HangsConfigRowLabel(label: label, value: value, showsChevron: false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("room.rules.guest.\(id)")
    }
}
