//
//  HangsQuizProgressHeader.swift
//  Hangs
//
//  #173 Track B, variant A3 (founder, 2026-09-07): the ONE header every question
//  type renders under the native toolbar — a segmented progress row over a small
//  mono meta row (category left, "1/10" right).
//
//  Two bugs it fixes at once:
//   - The old `HangsProgressBar` was fed `questionsAnswered / total` (0-based)
//     while the counter said `questionsAnswered + 1`, so question 1 of 10 showed
//     an EMPTY bar and the last question never filled. Progress here is 1-based:
//     the question you are looking at is the segment that is lit.
//   - MCQ and voice each drew their own category/counter row (`mcqTopRow` /
//     `metaRow`), and the MCQ one collided with the TestFlight chips. One row,
//     one layout, both modes.
//
//  Segments only read as "question N of M" while you can count them at a glance,
//  so a long set (> `maxSegments`) degrades to the linear bar — still 1-based.
//

import SwiftUI

struct HangsQuizProgressHeader: View {
    /// Display category, rendered lowercase (A3) — already localized by the caller.
    let category: String
    /// 1-based index of the question ON SCREEN.
    let current: Int
    /// Questions in the set.
    let total: Int
    /// #122 Variant C: the fill flips teal for the duration of a matched glow.
    var tint: Color?
    /// Pink while the mic is live — the counter is the glanceable mic tell (#83).
    var isRecording: Bool = false

    /// Past this many questions the dashes get too thin to count; fall back to
    /// the linear bar rather than draw a hairline comb.
    static let maxSegments = 15

    var body: some View {
        VStack(spacing: 6) {
            if total > 0, total <= Self.maxSegments {
                HangsSegmentedProgress(current: current, total: total, tint: tint)
            } else {
                HangsProgressBar(progress: Self.linearProgress(current: current, total: total), tint: tint)
            }

            HStack(spacing: 12) {
                Text(verbatim: category.lowercased())
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("question.category")

                Spacer(minLength: 12)

                Text(verbatim: Self.counterText(current: current, total: total))
                    .foregroundColor(isRecording ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.muted)
                    .accessibilityIdentifier("question.counter")
            }
            // A3: smaller than the 11pt row it replaces — the header is a
            // reference, not a headline.
            .font(.hangsMono(10, weight: .medium))
            .tracking(1.4)
            .padding(.horizontal, 24)
        }
    }

    /// 1-based fill for the linear fallback: question 1 of 10 is already 1/10
    /// done being asked, and the last question fills the bar.
    static func linearProgress(current: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(current) / Double(total)))
    }

    static func counterText(current: Int, total: Int) -> String {
        "\(max(current, 0))/\(max(total, 0))"
    }
}

/// The A3 progress row: one rounded segment per question, filled up to and
/// INCLUDING the current one. Pure `filled(_:)` so the 1-based contract is
/// assertable without rendering.
struct HangsSegmentedProgress: View {
    let current: Int
    let total: Int
    var tint: Color?

    /// Is the segment at this 0-based position lit? Question 1 lights segment 0.
    func isFilled(_ index: Int) -> Bool { index < current }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< max(total, 0), id: \.self) { index in
                Capsule()
                    .fill(isFilled(index)
                        ? (tint ?? Theme.Hangs.Colors.accentTeal)
                        : Theme.Hangs.Colors.mutedBorder)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Question \(current) of \(total)"))
        .accessibilityIdentifier("question.progress")
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 24) {
            HangsQuizProgressHeader(category: "Food and everyday life", current: 1, total: 10)
            HangsQuizProgressHeader(category: "Geography", current: 10, total: 10, isRecording: true)
            HangsQuizProgressHeader(category: "Long set", current: 7, total: 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 40)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
