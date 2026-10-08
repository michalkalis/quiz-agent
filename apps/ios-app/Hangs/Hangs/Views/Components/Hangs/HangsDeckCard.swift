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
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    private var style: Theme.Hangs.Category.Style { Theme.Hangs.Category.style(for: categoryId) }

    var body: some View {
        VStack(alignment: .leading, spacing: DeckCardMetrics.headerGap) {
            HStack(alignment: .center) {
                HangsCategoryChip(name: categoryName)
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
    static let headerGap: CGFloat = 10
    static let padding = EdgeInsets(top: 16, leading: 20, bottom: 18, trailing: 20)
}

extension HangsDeckCard where Accessory == EmptyView {
    init(categoryId: String?, categoryName: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(categoryId: categoryId, categoryName: categoryName, accessory: { EmptyView() }, content: content)
    }
}

/// White capsule with the category name in caps — readable on every category fill.
struct HangsCategoryChip: View {
    let name: String

    var body: some View {
        Text(name.uppercased())
            .font(.hangsOverline)
            .tracking(0.6)
            .lineLimit(1)
            .foregroundStyle(Theme.Hangs.Category.chipText)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .frame(minHeight: 28)
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
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .padding(.vertical, Theme.Hangs.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.chip, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
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
