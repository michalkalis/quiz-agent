//
//  RecapNumberRow.swift
//  Hangs
//
//  #216.3: one number of a recap, shared by the Profile card and the picture
//  it shares, plus the recap's own words.
//

import SwiftUI

/// One number of a recap: its caption, the value and the detail line.
struct RecapNumberRow: View {
    @Environment(\.locale) private var locale
    let card: StatCard
    let valueFont: Font

    static let captionOpacity = 0.8

    var body: some View {
        if let content = card.content {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                if let caption = StatCardCopy.caption(card.kind) {
                    Text(caption)
                        .font(.hangsCaption)
                        .opacity(Self.captionOpacity)
                }
                StatCardCopy.value(content, locale: locale)?
                    .font(valueFont)
                    .hangsHeadlineFit()
                StatCardCopy.detail(content)?
                    .font(.hangsCaption)
                    .opacity(Self.captionOpacity)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// The words of a recap that are not a stat card's.
enum RecapCopy {
    /// "Your October", "Your first recap", "Your year 2026".
    static func title(_ recap: PlayerRecap, locale: Locale) -> Text {
        switch recap.kind {
        case .first, nil:
            Text("Your first recap")
        case .year:
            Text("Your year \(recap.period.map { String($0.year) } ?? "")")
        case .month:
            Text("Your \(recap.monthName(locale: locale) ?? "")", comment: "Recap title with the month name, e.g. Your October")
        }
    }

    /// #240: the line the story picture travels with, so the friend has
    /// something to tap: what Trubbo is, then the site in the quiz language.
    static var shareMessage: String {
        let line = String(localized: "Try Trubbo, the quiz you play by voice.", bundle: .interface, locale: .interface, comment: "#240: text sent with the profile recap picture; the trubbo.app address follows on its own line")
        return line + "\n" + Config.homePageURL().absoluteString
    }
}
