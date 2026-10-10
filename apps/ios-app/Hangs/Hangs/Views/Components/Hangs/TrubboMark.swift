//
//  TrubboMark.swift
//  Hangs
//
//  #194 D2 — the logo (founder 2026-10-09, canvas "Kolo 5: logo", variant 2):
//  a question mark whose dot is a small wave of four tilted category cards.
//  Same geometry as the app icon layers (`AppIcon.icon/Assets`, 100-unit grid),
//  drawn in code so it stays sharp at any size and the hook follows the text
//  colour of its surroundings.
//

import SwiftUI

struct TrubboMark: View {
    /// Height of the mark; the width follows the logo's proportions.
    var height: CGFloat = 30

    /// The icon grid crop the mark sits in (x 27…73, y 8…87 of 100).
    private static let crop = CGRect(x: 27, y: 8, width: 46, height: 79)

    private struct Card {
        let center: CGPoint
        let size: CGSize
        let degrees: Double
        let fill: Color
    }

    private static let cards: [Card] = [
        Card(center: CGPoint(x: 36.5, y: 76), size: CGSize(width: 6, height: 12), degrees: -6, fill: Theme.Hangs.Category.style(for: "science-nature").fill),
        Card(center: CGPoint(x: 45.5, y: 76), size: CGSize(width: 6, height: 20), degrees: 4, fill: Theme.Hangs.Category.style(for: "sports").fill),
        Card(center: CGPoint(x: 54.5, y: 76), size: CGSize(width: 6, height: 14), degrees: -3, fill: Theme.Hangs.Category.style(for: "history").fill),
        Card(center: CGPoint(x: 63.5, y: 76), size: CGSize(width: 6, height: 9), degrees: 5, fill: Theme.Hangs.Category.style(for: "movies-music").fill),
    ]

    var body: some View {
        Canvas { context, size in
            let scale = size.height / Self.crop.height
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -Self.crop.minX, y: -Self.crop.minY)

            // The hook: SVG "M34 30 A16 16 0 1 1 62.3 40.3 Q50 46 50 55".
            var hook = Path()
            hook.move(to: CGPoint(x: 34, y: 30))
            hook.addArc(center: CGPoint(x: 50, y: 30.08), radius: 16,
                        startAngle: .degrees(180.3), endAngle: .degrees(39.7), clockwise: false)
            hook.addQuadCurve(to: CGPoint(x: 50, y: 55), control: CGPoint(x: 50, y: 46))
            context.stroke(hook, with: .foreground, style: StrokeStyle(lineWidth: 11, lineCap: .round))

            for card in Self.cards {
                var piece = context
                piece.translateBy(x: card.center.x, y: card.center.y)
                piece.rotate(by: .degrees(card.degrees))
                let rect = CGRect(x: -card.size.width / 2, y: -card.size.height / 2,
                                  width: card.size.width, height: card.size.height)
                // design-token: logo geometry on the icon's 100-unit grid, not a UI radius
                piece.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(card.fill))
            }
        }
        .frame(width: height * Self.crop.width / Self.crop.height, height: height)
        .accessibilityHidden(true)
    }
}

#if DEBUG
    #Preview {
        HStack(spacing: 24) {
            TrubboMark(height: 30)
            TrubboMark(height: 80)
        }
        .padding(24)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
