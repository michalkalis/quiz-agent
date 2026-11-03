//
//  CrowdStripRow.swift
//  Hangs
//
//  #205.5: how the other players did on this question, on the result card of
//  a daily challenge. #224 (canvas B1b): one quiet line in the card's bottom
//  row, left of the source link, sentence and meter in the muted text colour.
//

import SwiftUI

struct CrowdStripRow: View {
    let strip: CrowdStrip

    private enum Metrics {
        /// Design slot: the meter is a short gauge beside the sentence.
        static let meterWidth: CGFloat = 40
        static let meterHeight: CGFloat = 4
    }

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            Text(verbatim: strip.text)
                .font(.hangsCaption.weight(.semibold))
                .lineLimit(2)
            if let fraction = strip.knewFraction {
                meter(fraction)
            }
        }
        .foregroundStyle(Theme.Hangs.Colors.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: strip.text))
        .accessibilityIdentifier("result.crowd")
    }

    private func meter(_ fraction: Double) -> some View {
        Capsule()
            .fill(Theme.Hangs.Colors.track)
            .frame(width: Metrics.meterWidth, height: Metrics.meterHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.Hangs.Colors.muted)
                    .frame(width: Metrics.meterWidth * fraction)
            }
            .accessibilityIdentifier("result.crowd.meter")
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 12) {
            CrowdStripRow(strip: CrowdStrip(kind: .rare, text: "Vedel 1 z 3.", others: 3, knew: 1))
            CrowdStripRow(strip: CrowdStrip(kind: .first, text: "Dnes si prvý.", others: 0, knew: 0))
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bgCard)
    }
#endif
