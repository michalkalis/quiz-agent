//
//  RoomPlayerAvatar.swift
//  Hangs
//
//  #212: a player's colour dot with their initial.
//

import SwiftUI

struct RoomPlayerAvatar: View {
    let name: String
    let color: String?
    var size: CGFloat = 32

    var body: some View {
        let style = Theme.Hangs.Category.player(color)
        Text(verbatim: name.first.map { String($0).uppercased() } ?? "?")
            .font(.hangsBody(size * 0.47, weight: .bold))
            .foregroundStyle(style.text)
            .frame(width: size, height: size)
            .background(Circle().fill(style.fill))
            .accessibilityHidden(true)
    }
}
