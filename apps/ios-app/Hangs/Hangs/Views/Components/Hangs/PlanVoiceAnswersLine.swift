//
//  PlanVoiceAnswersLine.swift
//  Hangs
//
//  Free tier split (founder 2026-11-21, D2): the voice answers left this
//  month, shown only in the Profile's plan card under the free questions it
//  is part of. Nothing on Home. Absent when voice is not limited (Trubbo
//  Plus, pack credits, an older server).
//

import SwiftUI

struct PlanVoiceAnswersLine: View {
    let remaining: Int
    let limit: Int

    var body: some View {
        Label {
            if remaining > 0 {
                Text("By voice: \(remaining) of \(limit) left")
            } else {
                Text("Voice answers used up this month")
            }
        } icon: {
            Image(systemName: remaining > 0 ? "mic.fill" : "mic.slash")
                .accessibilityHidden(true)
        }
        .font(.hangsCaption)
        .foregroundStyle(Theme.Hangs.Colors.muted)
        .accessibilityIdentifier("home.planVoiceAnswers")
    }
}
