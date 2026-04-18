//
//  HangsBlocks.swift
//  CarQuiz
//
//  Big display blocks — pink hero ("HANGS", "MASTER!"), verdict badges, etc.
//

import SwiftUI

/// Big rectangular hero block with heavy display text inside.
/// Used for "HANGS" hero, "MASTER!" on completion, "INCORRECT!" banner.
struct HangsHeroBlock: View {
    let text: String
    var fill: Color = Theme.Hangs.Colors.accent
    var textColor: Color = Theme.Hangs.Colors.textOnAccent
    var font: Font = .hangsBlock
    var paddingH: CGFloat = 20
    var paddingV: CGFloat = 22
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        HStack {
            if alignment != .leading { Spacer(minLength: 0) }
            Text(text)
                .font(font)
                .tracking(-1)
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if alignment != .trailing { Spacer(minLength: 0) }
        }
        .padding(.horizontal, paddingH)
        .padding(.vertical, paddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
    }
}

/// Verdict banner — colored card with `[ VERDICT ]` label + big result text + point delta.
struct HangsVerdictCard: View {
    let isCorrect: Bool
    let pointsDelta: String      // e.g. "+1.0", "+0.0"

    private var accentColor: Color {
        isCorrect ? Theme.Hangs.Colors.success : Theme.Hangs.Colors.error
    }

    private var resultText: String {
        isCorrect ? "CORRECT" : "INCORRECT"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HangsTerminalLabel(text: "[ VERDICT ]", color: accentColor)
                Spacer()
                HangsTerminalLabel(text: isCorrect ? "EVAL.PASS" : "EVAL.FAIL", color: accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(accentColor.opacity(0.15))

            HStack(alignment: .firstTextBaseline) {
                Text(resultText)
                    .font(.hangsDisplayMD)
                    .tracking(-0.5)
                    .foregroundColor(accentColor)
                Spacer()
                Text(pointsDelta)
                    .font(.system(size: 28, weight: .heavy, design: .default))
                    .foregroundColor(accentColor)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.Hangs.Colors.bg)
        .overlay(
            Rectangle().stroke(accentColor, lineWidth: 1)
        )
    }
}

/// Answer comparison row — `YOUR_ANSWER ......... 1989`
struct HangsAnswerRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.Hangs.Colors.textPrimary

    var body: some View {
        HStack {
            Text(label)
                .font(.hangsMonoLabel)
                .foregroundColor(Theme.Hangs.Colors.textTertiary)
                .tracking(0.5)
            Spacer()
            Text(value)
                .font(.hangsMonoValue)
                .foregroundColor(valueColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.Hangs.Colors.bgCard)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 16) {
        HangsHeroBlock(text: "HANGS")
        HangsHeroBlock(text: "MASTER!")
        HangsVerdictCard(isCorrect: true, pointsDelta: "+1.0")
        HangsVerdictCard(isCorrect: false, pointsDelta: "+0.0")
        VStack(spacing: 1) {
            HangsAnswerRow(label: "YOUR_ANSWER", value: "1989")
            HangsAnswerRow(label: "CORRECT_ANSWER", value: "1989", valueColor: Theme.Hangs.Colors.success)
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Hangs.Colors.bg)
    .preferredColorScheme(.dark)
}
#endif
