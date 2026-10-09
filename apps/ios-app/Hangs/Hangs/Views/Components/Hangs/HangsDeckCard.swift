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
    let categoryId: String?
    let categoryName: String
    /// The screen's identifier for the category chip (`question.category`).
    var categoryIdentifier: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    private var style: Theme.Hangs.Category.Style { Theme.Hangs.Category.style(for: categoryId) }

    var body: some View {
        VStack(alignment: .leading, spacing: DeckCardMetrics.headerGap) {
            HStack(alignment: .center) {
                HangsCategoryChip(name: categoryName, identifier: categoryIdentifier)
                Spacer(minLength: Theme.Hangs.Spacing.xs)
                accessory()
            }
            content()
        }
        .foregroundStyle(style.text)
        .padding(DeckCardMetrics.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            // Shadow on the plate only — on the whole view it blurs the text too.
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.deck, style: .continuous)
                .fill(style.fill)
                .hangsShadow(Theme.Hangs.Shadow.raised)
        )
    }
}

private enum DeckCardMetrics {
    static let chipHeight: CGFloat = 28
    /// Canvas `card-in`: 28pt from the trailing side over 420 ms.
    static let arrivalOffset: CGFloat = 28
    static let arrivalDuration = 0.42
    static let headerGap: CGFloat = 10
    static let padding = EdgeInsets(top: 16, leading: 20, bottom: 18, trailing: 20)
}

extension HangsDeckCard where Accessory == EmptyView {
    init(
        categoryId: String?,
        categoryName: String,
        categoryIdentifier: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            categoryId: categoryId,
            categoryName: categoryName,
            categoryIdentifier: categoryIdentifier,
            accessory: { EmptyView() },
            content: content
        )
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
            HangsDeckCard(categoryId: "geography-world", categoryName: "Geografia a svet") {
                Text("Ktoré mesto je hlavným mestom Austrálie?").font(.hangsDisplay(40))
            }
            HangsDeckCard(categoryId: "sports", categoryName: "Šport") {
                HangsAnswerSticker(text: "Jedenásť")
            }
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
