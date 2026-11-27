//
//  DailyBonusLeftLine.swift
//  Hangs
//
//  #205 — daily challenge, sub-task 205.8: the one quiet line that says how
//  many extra questions are left today. On the Home card and the round end.
//

import SwiftUI

struct DailyBonusLeftLine: View {
    let left: Int

    var body: some View {
        Text("Reward: \(left) extra questions left today.")
            .font(.hangsBody)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
