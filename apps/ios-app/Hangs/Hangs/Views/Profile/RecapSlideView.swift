//
//  RecapSlideView.swift
//  Hangs
//
//  #213.5 (canvas "Lišta a Profil", section 3, approved 2026-10-28): one
//  slide of the recap story — a small caption, one big line, one detail line,
//  the wordmark at the bottom. The same view is rendered into the shared image.
//

import SwiftUI

struct RecapSlideView: View {
    @Environment(\.locale) private var locale
    let slide: RecapSlide
    let recap: PlayerRecap
    let style: Theme.Hangs.Category.Style

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
            Spacer(minLength: 0)
            if let kicker {
                kicker
                    .font(.hangsOverline)
                    .textCase(.uppercase)
                    .opacity(Metrics.kickerOpacity)
            }
            if let hero {
                hero
                    .font(.hangsDisplayMD)
                    .textCase(.uppercase)
                    .hangsHeadlineFit()
                    .accessibilityAddTraits(.isHeader)
            }
            if let detail {
                detail
                    .font(.hangsLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HangsBrandMark(size: Metrics.brand, color: style.text)
        }
        .padding(.horizontal, Theme.Hangs.Spacing.xl)
        .padding(.vertical, Theme.Hangs.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(style.text)
        .background(style.fill.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }

    private var kicker: Text? {
        switch slide {
        case .intro: RecapCopy.title(recap, locale: locale)
        case let .card(kind, _): StatCardCopy.caption(kind).map { Text($0) }
        case .playerType: Text("Your player type")
        }
    }

    private var hero: Text? {
        switch slide {
        case let .intro(answers, _): Text("\(answers) questions")
        case let .card(_, content): StatCardCopy.value(content, locale: locale)
        case let .playerType(type): Text(RecapCopy.playerTypeName(type))
        }
    }

    private var detail: Text? {
        switch slide {
        case let .intro(_, minutes): StatCardCopy.detail(.totals(answers: 0, minutes: minutes))
        case let .card(_, content): StatCardCopy.detail(content)
        case let .playerType(type): Text(RecapCopy.playerTypeLine(type))
        }
    }

    /// Totals on ink, the player type on lime, the cards in between in turn.
    static func style(at index: Int, in slides: [RecapSlide]) -> Theme.Hangs.Category.Style {
        switch slides[index] {
        case .intro: return Theme.Hangs.Recap.intro
        case .playerType: return Theme.Hangs.Recap.finale
        case .card:
            let cardIndex = slides[..<index].count(where: { if case .card = $0 { true } else { false } })
            return Theme.Hangs.Recap.cards[cardIndex % Theme.Hangs.Recap.cards.count]
        }
    }

    private enum Metrics {
        static let kickerOpacity = 0.8
        static let brand: CGFloat = 20
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

    static func playerTypeName(_ type: String) -> LocalizedStringKey {
        switch type {
        case "night_owl": "Night owl"
        case "road_tripper": "Road tripper"
        case "speedster": "Speedster"
        case "specialist": "Specialist"
        case "all_rounder": "All-rounder"
        default: "Explorer"
        }
    }

    static func playerTypeLine(_ type: String) -> LocalizedStringKey {
        switch type {
        case "night_owl": "You like to play late at night."
        case "road_tripper": "The quiz keeps you company on the road."
        case "speedster": "You answer in a flash."
        case "specialist": "One category is clearly yours."
        case "all_rounder": "You do well in every category."
        default: "You are still getting to know the quiz."
        }
    }
}
