//
//  RoomRevealRows.swift
//  Hangs
//
//  #224.4: what everyone said after a question. A–D questions list the
//  options with the faces of who picked each; typed answers list each player
//  with their text and points.
//

import SwiftUI

/// A–D: every option, the right one marked, under it the faces that picked it.
struct RoomOptionRows: View {
    let options: [RoomViewModel.OptionRow]

    var body: some View {
        HangsCard {
            VStack(spacing: 0) {
                ForEach(options) { option in
                    row(option)
                    if option.id != options.last?.id { HangsDivider() }
                }
            }
        }
    }

    private func row(_ option: RoomViewModel.OptionRow) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            if option.isCorrect {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: Metrics.letter))
                    .foregroundStyle(Theme.Hangs.Colors.textOnAction, Theme.Hangs.Colors.greenCheck)
                    .frame(width: Metrics.letterSide)
                    .accessibilityLabel(Text("correct"))
            } else {
                Text(verbatim: option.letter)
                    .font(.hangsMonoLabel)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .frame(width: Metrics.letterSide)
            }
            Text(verbatim: option.text)
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            if option.pickers.isEmpty {
                Text("nobody")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            } else {
                HStack(spacing: Metrics.faceOverlap) {
                    ForEach(option.pickers) { picker in
                        RoomPlayerAvatar(name: picker.name, color: picker.color, size: Metrics.face)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.vertical, Theme.Hangs.Spacing.xs)
        .frame(minHeight: Metrics.rowHeight)
        .background(option.isCorrect ? Theme.Hangs.Colors.liveSoft : Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(option.letter) \(option.text)"))
        .accessibilityValue(Text(verbatim: option.pickers.map(\.name).joined(separator: ", ")))
        .accessibilityIdentifier("room.reveal.option.\(option.id)")
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 52
        static let letter: CGFloat = 22
        static let letterSide: CGFloat = 28
        static let face: CGFloat = 26
        static let faceOverlap: CGFloat = -6
    }
}

/// Typed answers: one line per player with the text, the points and a mark.
struct RoomAnswerRows: View {
    let rows: [RoomViewModel.RevealRow]

    var body: some View {
        HangsCard {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: Theme.Hangs.Spacing.sm) {
                        RoomPlayerAvatar(name: row.name, color: row.color, size: Metrics.face)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: Theme.Hangs.Spacing.xxs) {
                                Text(verbatim: row.name)
                                    .font(.hangsLabel)
                                    .foregroundStyle(Theme.Hangs.Colors.ink)
                                if row.isYou {
                                    Text("(you)")
                                        .font(.hangsCaption)
                                        .foregroundStyle(Theme.Hangs.Colors.muted)
                                }
                            }
                            Group {
                                if let answer = row.answer {
                                    Text(verbatim: answer)
                                } else {
                                    Text("no answer")
                                }
                            }
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        mark(row)
                    }
                    .padding(.horizontal, Theme.Hangs.Spacing.md)
                    .frame(minHeight: Metrics.rowHeight)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("room.reveal.row.\(row.id)")
                    if row.id != rows.last?.id { HangsDivider() }
                }
            }
        }
    }

    private func mark(_ row: RoomViewModel.RevealRow) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            if row.isCorrect {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Hangs.Colors.greenCheck)
                    .accessibilityLabel(Text("correct"))
            }
            Text(verbatim: Self.points(row.points))
                .font(.hangsMonoValue)
                .monospacedDigit()
                .foregroundStyle(row.isCorrect ? Theme.Hangs.Colors.ink : Theme.Hangs.Colors.muted)
        }
    }

    static func points(_ points: Double) -> String {
        let text = points.formatted(.number.precision(.fractionLength(0 ... 1)))
        return points > 0 ? "+\(text)" : text
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 52
        static let face: CGFloat = 28
    }
}
