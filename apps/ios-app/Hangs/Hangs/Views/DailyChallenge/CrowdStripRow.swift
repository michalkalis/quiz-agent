//
//  CrowdStripRow.swift
//  Hangs
//
//  #205.5: how the other players did on this question, on the result card of
//  a daily challenge. Founder decision 2 (2026-10-15): always one place,
//  directly under the answer sticker, on a right and a wrong answer alike.
//  One compact row on the sticker's white plate, so the zero-scroll result
//  layout (#127) keeps its room: the server's sentence, then a thin meter of
//  how many of the others knew it ("Dnes si prvý." has nothing to measure).
//

import SwiftUI

struct CrowdStripRow: View {
    let strip: CrowdStrip

    private enum Metrics {
        /// Design slot: the meter is a short gauge beside the sentence.
        static let meterWidth: CGFloat = 56
        static let meterHeight: CGFloat = 4
        /// The plate is white in both modes, so the meter's track is the
        /// plate's ink at the `track` token's strength, not `track` itself.
        static let trackOpacity = 0.14
    }

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            Text(verbatim: strip.text)
                .font(.hangsCaption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let fraction = strip.knewFraction {
                meter(fraction)
            }
        }
        .foregroundStyle(Theme.Hangs.Category.chipText)
        .padding(.horizontal, Theme.Hangs.Spacing.sm)
        .padding(.vertical, Theme.Hangs.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.chip, style: .continuous)
                .fill(Theme.Hangs.Category.chipFill)
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: strip.text))
        .accessibilityIdentifier("result.crowd")
    }

    private func meter(_ fraction: Double) -> some View {
        Capsule()
            .fill(Theme.Hangs.Category.chipText.opacity(Metrics.trackOpacity))
            .frame(width: Metrics.meterWidth, height: Metrics.meterHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.Hangs.Category.chipText)
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
        .background(Theme.Hangs.Category.correct.fill)
    }
#endif
