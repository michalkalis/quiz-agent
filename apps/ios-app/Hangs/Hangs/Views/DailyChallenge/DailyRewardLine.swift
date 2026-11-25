//
//  DailyRewardLine.swift
//  Hangs
//
//  #248.3: the one muted line on the daily round end that tells what playing
//  earned today. The Home card keeps `DailyBonusLeftLine` ("You have N ...").
//

import SwiftUI

struct DailyRewardLine: View {
    let left: Int

    var body: some View {
        Text("As a reward you get \(left) extra questions today.")
            .font(.hangsBody)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
