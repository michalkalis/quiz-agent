//
//  PaywallHeroDeck.swift
//  Hangs
//
//  #194 C6 — the paywall's small fanned card stack (canvas Bg-Paywall,
//  Bg-PaywallDone, Bg-PaywallOffline): two cards behind a front card that
//  carries the state's glyph. Static decoration, hidden from VoiceOver.
//

import SwiftUI

struct PaywallHeroDeck<Glyph: View>: View {
    /// Back to front; the last fill is the front card the glyph sits on.
    let fills: [Color]
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        ZStack {
            ForEach(fills.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                    .fill(fills[index])
                    .strokeBorder(Theme.Hangs.Colors.hairline)
                    .frame(width: Metrics.card.width, height: Metrics.card.height)
                    .hangsShadow(Theme.Hangs.Shadow.card)
                    .rotationEffect(Metrics.angle(index, of: fills.count), anchor: .bottom)
                    .offset(x: Metrics.offset(index, of: fills.count))
            }
            glyph()
                .offset(y: Metrics.glyphLift)
        }
        .frame(height: Metrics.height)
        .accessibilityHidden(true)
    }

    private typealias Metrics = PaywallHeroDeckMetrics
}

private enum PaywallHeroDeckMetrics {
    static let card = CGSize(width: 64, height: 86)
    static let height: CGFloat = 104
    static let glyphLift: CGFloat = -4
    /// Back cards fan out to either side; the front card leans slightly.
    static func angle(_ index: Int, of count: Int) -> Angle {
        let fan: [Double] = [-14, 12, -3]
        return .degrees(fan[(fan.count - count + index).clamped(to: 0 ... fan.count - 1)])
    }

    static func offset(_ index: Int, of count: Int) -> CGFloat {
        let shift: [CGFloat] = [-22, 22, 0]
        return shift[(shift.count - count + index).clamped(to: 0 ... shift.count - 1)]
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

#if DEBUG
    #Preview {
        PaywallHeroDeck(fills: [
            Theme.Hangs.Category.style(for: "history").fill,
            Theme.Hangs.Category.style(for: "science-nature").fill,
            Theme.Hangs.Category.style(for: "geography-world").fill,
        ]) {
            Image(systemName: "infinity").font(.hangsHeading).foregroundStyle(.white)
        }
        .padding(40)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
