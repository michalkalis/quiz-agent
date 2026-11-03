//
//  HangsDeckCard.swift
//  Hangs
//
//  #194 B2 — "Sklo nad kartami": the question and the result sit on an opaque
//  card in their category's colour; glass is only the control layer around it.
//

import SwiftUI

/// The card a question or a result is printed on: category fill, 32pt
/// continuous corners, the category chip top-left and an optional accessory
/// top-right (replay, verdict badge). Fills the space it is given; content
/// below the header is the caller's (question text, verdict, answer sticker).
struct HangsDeckCard<Accessory: View, Content: View>: View {
    let style: Theme.Hangs.Category.Style
    /// The chip's text; nil hides the chip (a category outside the taxonomy).
    let categoryName: String?
    /// The screen's identifier for the category chip (`question.category`).
    var categoryIdentifier: String?
    /// #224 (calm results): a neutral surface instead of the category colour. The
    /// category shrinks to a dot in its colour plus its name, so a screen that is
    /// read (a result) is not also a colour field.
    var isCalm = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DeckCardMetrics.headerGap) {
            HStack(alignment: .center) {
                if let categoryName {
                    if isCalm {
                        HangsCategoryDotLabel(name: categoryName, dot: style.fill, identifier: categoryIdentifier)
                    } else {
                        HangsCategoryChip(name: categoryName, identifier: categoryIdentifier)
                    }
                }
                Spacer(minLength: Theme.Hangs.Spacing.xs)
                accessory()
            }
            // Keeps the header row's height when there is neither chip nor accessory.
            .frame(minHeight: DeckCardMetrics.chipHeight)
            content()
        }
        .foregroundStyle(isCalm ? Theme.Hangs.Colors.ink : style.text)
        .padding(DeckCardMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(plate)
    }

    @ViewBuilder private var plate: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
        if isCalm {
            shape.fill(Theme.Hangs.Colors.bgCard)
                .overlay(shape.strokeBorder(Theme.Hangs.Colors.hairline, lineWidth: 1))
        } else {
            // Shadow on the plate only — on the whole view it blurs the text too.
            shape.fill(style.fill).hangsShadow(Theme.Hangs.Shadow.raised)
        }
    }
}

private enum DeckCardMetrics {
    static let chipHeight: CGFloat = 28
    static let dot: CGFloat = 8
    /// Canvas `card-in`: 28pt from the trailing side over 420 ms.
    static let arrivalOffset: CGFloat = 28
    static let arrivalDuration = 0.42
    static let headerGap: CGFloat = 10
    static let padding = EdgeInsets(top: 16, leading: 20, bottom: 18, trailing: 20)
}

extension HangsDeckCard where Accessory == EmptyView {
    init(
        style: Theme.Hangs.Category.Style,
        categoryName: String?,
        categoryIdentifier: String? = nil,
        isCalm: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            style: style,
            categoryName: categoryName,
            categoryIdentifier: categoryIdentifier,
            isCalm: isCalm,
            accessory: { EmptyView() },
            content: content
        )
    }
}

/// #198: what a quiz card shows for a question — its fill and chip. A custom
/// pack's question wears the pack's own colour and says "Custom pack"; any
/// other takes its category's colour and name, and a category outside the
/// taxonomy gets the cobalt fallback and no chip (never a raw id).
struct DeckIdentity {
    let style: Theme.Hangs.Category.Style
    let chipName: String?
    /// The taxonomy id the colour comes from; nil for the cobalt fallback.
    let paletteId: String?

    init(category: String?, packId: String?) {
        if let packId {
            paletteId = Theme.Hangs.Category.paletteId(forPack: packId)
            chipName = String(localized: "Custom pack", bundle: .interface, locale: .interface, comment: "Chip on a question card dealt from the player's own pack")
        } else {
            paletteId = category.flatMap { Theme.Hangs.Category.taxonomy.contains($0) ? $0 : nil }
            chipName = category.flatMap(Config.categoryDisplayName(for:))
        }
        style = Theme.Hangs.Category.style(for: paletteId)
    }

    /// #198 round 2: the card for a result that is not a right answer — its
    /// own colour, unless that is the correct-answer mint.
    var notCorrectStyle: Theme.Hangs.Category.Style {
        paletteId == Theme.Hangs.Category.correctId ? Theme.Hangs.Category.notCorrect : style
    }
}

/// #194 B3: a card being dealt — it slides in from the trailing side and fades
/// up each time `trigger` changes. It is at rest on the first render, so a
/// snapshot shows the card in place, and a caller under Reduce Motion simply
/// never changes the trigger.
private struct HangsCardArrival: ViewModifier {
    let trigger: Int

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, progress in
            view
                .opacity(progress)
                .offset(x: (1 - progress) * DeckCardMetrics.arrivalOffset)
        } keyframes: { _ in
            KeyframeTrack {
                MoveKeyframe(0.0)
                SpringKeyframe(1.0, duration: DeckCardMetrics.arrivalDuration, spring: .smooth)
            }
        }
    }
}

extension EnvironmentValues {
    /// #194 B3: whether cards are dealt with motion at all. Snapshot tests turn
    /// it off — a frozen frame must show the card at rest, not mid-arrival.
    /// (Reduce Motion is checked by the caller as well.)
    @Entry var hangsCardMotion = true
}

extension View {
    /// Plays the card arrival whenever `trigger` changes (see `HangsCardArrival`).
    func hangsCardArrival(trigger: Int) -> some View {
        modifier(HangsCardArrival(trigger: trigger))
    }
}

/// White capsule with the category name in caps — readable on every category fill.
struct HangsCategoryChip: View {
    let name: String
    var identifier: String?

    var body: some View {
        if let identifier {
            chip.accessibilityIdentifier(identifier)
        } else {
            chip
        }
    }

    private var chip: some View {
        Text(name.uppercased())
            .font(.hangsOverline)
            .tracking(0.6)
            .lineLimit(1)
            .foregroundStyle(Theme.Hangs.Category.chipText)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .frame(minHeight: DeckCardMetrics.chipHeight)
            .background(Capsule().fill(Theme.Hangs.Category.chipFill))
    }
}

/// The calm card's category mark: a dot in the category colour and the name in
/// the quiet text colour (#224, B1b).
struct HangsCategoryDotLabel: View {
    let name: String
    let dot: Color
    var identifier: String?

    var body: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            Circle().fill(dot).frame(width: DeckCardMetrics.dot, height: DeckCardMetrics.dot)
            Text(name)
                .font(.hangsCaption.weight(.semibold))
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier ?? "deck.category")
    }
}

/// The answer "sticker": the answer on its own white plate inside a result
/// card, so it reads first on any category colour (#194 B2).
struct HangsAnswerSticker: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hangsTitle)
            // R-Result: ink on white in both modes, like the category chip —
            // the one plate that reads on every category fill.
            .foregroundStyle(Theme.Hangs.Category.chipText)
            .multilineTextAlignment(.leading)
            // A long answer shrinks before it takes a third line: the card
            // keeps its room for "why" (the screen never scrolls).
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .padding(.vertical, Theme.Hangs.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.chip, style: .continuous)
                    .fill(Theme.Hangs.Category.chipFill)
            )
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 16) {
            HangsDeckCard(style: Theme.Hangs.Category.style(for: "geography-world"), categoryName: "Geografia a svet") {
                Text("Ktoré mesto je hlavným mestom Austrálie?").font(.hangsDisplay(40))
            }
            HangsDeckCard(style: Theme.Hangs.Category.style(for: "sports"), categoryName: "Šport") {
                HangsAnswerSticker(text: "Jedenásť")
            }
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
