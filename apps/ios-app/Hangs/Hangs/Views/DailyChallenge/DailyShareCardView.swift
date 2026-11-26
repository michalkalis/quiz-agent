//
//  DailyShareCardView.swift
//  Hangs
//
//  #249.6 (founder 2026-11-26): the picture a shared daily result carries in
//  the share sheet's link header. The friend's chat preview shows the same
//  card, drawn by the server (`apps/quiz-agent/app/shared_quiz/card.py`; keep
//  the two alike): "Trubbo · daily challenge", the day, the big score, the
//  mark row and a hook. No question, no answer: nothing that spoils the day.
//  Words follow the quiz language, like the share text.
//

import SwiftUI
import UIKit

struct DailyShareCardView: View {
    static let size = CGSize(width: 1200, height: 630)

    /// Card-pixel measures (the card is drawn at 1200 x 630, not in screen points).
    private enum Metrics {
        static let leading: CGFloat = 80
        static let top: CGFloat = 52
        static let labelGap: CGFloat = 8
        static let scoreGap: CGFloat = 4
        static let tilesGap: CGFloat = 14
        static let hookGap: CGFloat = 28
        static let tileSpacing: CGFloat = 16
        static let cardRadius: CGFloat = 30
    }

    let day: DailyChallengeDay
    let language: String
    let marks: [Bool?]
    let score: Int
    let total: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Theme.Hangs.ShareCard.gradientStart, Theme.Hangs.ShareCard.gradientEnd],
                startPoint: .leading,
                endPoint: .trailing
            )
            decoration
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "TRUBBO")
                    .font(face(40, .heavy))
                    .tracking(4)
                Text(verbatim: "\(DailyShareText.challengeName(language: language)) \(day.label(languageCode: language))".uppercased())
                    .font(face(34, .bold))
                    .tracking(2)
                    .padding(.top, Metrics.labelGap)
                Text(verbatim: "\(score)/\(total)")
                    .font(face(200, .heavy))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: 200, alignment: .top)
                    .padding(.top, Metrics.scoreGap)
                tiles
                    .padding(.top, Metrics.tilesGap)
                Text(verbatim: Self.hook(language: language))
                    .font(face(56, .heavy))
                    .foregroundStyle(Theme.Hangs.ShareCard.hook)
                    .padding(.top, Metrics.hookGap)
            }
            .foregroundStyle(Theme.Hangs.ShareCard.text)
            .padding(.leading, Metrics.leading)
            .padding(.top, Metrics.top)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    private var tiles: some View {
        let shown = Array(marks.prefix(10))
        let side = min(92, (700 - 16 * CGFloat(max(shown.count - 1, 0))) / CGFloat(max(shown.count, 1)))
        return HStack(spacing: Metrics.tileSpacing) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, mark in
                tile(mark, side: side)
            }
        }
    }

    @ViewBuilder private func tile(_ mark: Bool?, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side / 4, style: .continuous)
        switch mark {
        case true?:
            shape.fill(Theme.Hangs.ShareCard.right).frame(width: side, height: side)
                .overlay(Image(systemName: "checkmark").font(.system(size: side * 0.42, weight: .heavy)).foregroundStyle(Theme.Hangs.ShareCard.glyph))
        case false?:
            shape.fill(Theme.Hangs.ShareCard.wrong).frame(width: side, height: side)
                .overlay(Image(systemName: "xmark").font(.system(size: side * 0.38, weight: .heavy)).foregroundStyle(Theme.Hangs.ShareCard.glyph))
        case nil:
            shape.strokeBorder(Theme.Hangs.ShareCard.text, lineWidth: 4).frame(width: side, height: side)
        }
    }

    /// Two tilted cards on the right, as on the app's other share pictures.
    private var decoration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Theme.Hangs.ShareCard.right)
                .frame(width: 330, height: 440)
                .rotationEffect(.degrees(8))
                .position(x: 985, y: 560)
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Theme.Hangs.ShareCard.wrong)
                .frame(width: 330, height: 440)
                .rotationEffect(.degrees(-12))
                .position(x: 1095, y: 340)
        }
    }

    private func face(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(Theme.Hangs.Fonts.contentFaceName(for: weight, language: language), fixedSize: size)
    }

    /// Hardcoded per quiz language, like the share text (the card is the
    /// quiz's, not the interface's).
    nonisolated static func hook(language: String) -> String {
        switch language {
        case "sk": "Dáš viac?"
        case "cs": "Dáš víc?"
        case "uk": "Зможеш більше?"
        default: "Can you beat it?"
        }
    }

    /// The card as a picture for the share sheet's link header. 1200 x 630 px
    /// (scale 1), the size chat apps expect.
    @MainActor static func image(day: DailyChallengeDay, language: String, marks: [Bool?], score: Int, total: Int) -> UIImage? {
        let renderer = ImageRenderer(content: DailyShareCardView(day: day, language: language, marks: marks, score: score, total: total))
        renderer.scale = 1
        return renderer.uiImage
    }
}
