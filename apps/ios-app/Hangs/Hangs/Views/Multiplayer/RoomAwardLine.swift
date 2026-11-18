//
//  RoomAwardLine.swift
//  Hangs
//
//  #240.9: one small award at the end of a game together (fastest right
//  answer, nobody else knew, longest streak), on the final screen and on the
//  ranking picture players send.
//

import SwiftUI

struct RoomAwardLine: View {
    @Environment(\.locale) private var locale
    let row: RoomViewModel.AwardRow
    let textColor: Color
    let captionColor: Color

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            RoomPlayerAvatar(name: row.name, color: row.color, size: Metrics.face)
            // Detail beside the labels while all fit one line; under them when
            // not, so "2,3 s, otázka 1" never ends in "…" at large text.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    labels
                    Spacer(minLength: 0)
                    detailText
                }
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    labels
                    detailText
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            title
                .font(.hangsCaption)
                .foregroundStyle(captionColor)
            Text(verbatim: row.name)
                .font(.hangsLabel)
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
    }

    private var detailText: some View {
        detail
            .font(.hangsMonoValue)
            .monospacedDigit()
            .foregroundStyle(textColor)
    }

    private var title: Text {
        switch row.kind {
        case .fastest: Text("Fastest right answer")
        case .onlyOne: Text("Nobody else knew")
        case .streak: Text("Longest streak")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch row.kind {
        case .fastest:
            if let seconds = row.seconds, let number = row.questionNumber {
                Text("\(seconds.formatted(.number.precision(.fractionLength(1)).locale(locale))) s, question \(number)")
            }
        case .onlyOne:
            if let count = row.count, count > 1 {
                Text(verbatim: "×\(count)")
            } else if let number = row.questionNumber {
                Text("Question \(number)")
            }
        case .streak:
            if let count = row.count {
                Text("\(count) right in a row")
            }
        }
    }

    private enum Metrics {
        static let face: CGFloat = 28
    }
}
