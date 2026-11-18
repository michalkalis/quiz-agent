//
//  HomeCategoryDeck.swift
//  Hangs
//
//  #194 C1 — the Home card deck ("Sklo nad kartami", R-Home): the chosen
//  categories fanned behind a white front card that names the round. Pure
//  decoration of state the pills below already state, dropped at accessibility
//  text sizes (content first).
//
//  #224.6 (canvas C1, founder 2026-11-03): the deck is also the single-category
//  stepper. Tapping its right half brings the next category's card forward,
//  the left half the previous one (`HomeCategoryCycleCards`); a multi-category
//  selection (C4) keeps the fan of its picks and leaves it on the first tap.
//  For VoiceOver it is one adjustable element instead of two half-taps.
//
//  #236: in family mode the same deck steps through the age band's topics
//  (`HomeDeckCard.topics`), one topic per round, never a multi-selection.
//

import SwiftUI

struct HomeCategoryDeck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lift: HomeCategoryCycleCards.Lift?
    @State private var liftTask: Task<Void, Never>?

    /// The cycle the deck steps through.
    let cards: [HomeDeckCard]
    /// Index of the front card in `cards`.
    let front: Int
    /// Selected category ids; more than one fans the picks (categories only).
    let selectedCategories: [String]
    /// The front card's title: the same value the pill under the deck shows.
    let title: String
    let questionCount: Int
    /// What VoiceOver calls the deck ("Categories", "Topic").
    let label: LocalizedStringKey
    /// The deck's identifier; its halves add `.previous` / `.next`.
    let identifier: String
    /// A tap on the left / right half (or VoiceOver decrement / increment).
    let onStep: (CategoryCycle.Direction, CategoryStepInput) -> Void

    /// The category deck as before #236.
    init(
        selectedCategories: [String],
        title: String,
        questionCount: Int,
        onStep: @escaping (CategoryCycle.Direction, CategoryStepInput) -> Void
    ) {
        self.init(
            cards: HomeDeckCard.categories,
            front: CategoryCycle.position(of: selectedCategories),
            selectedCategories: selectedCategories,
            title: title,
            questionCount: questionCount,
            label: "Categories",
            identifier: "home.categoryDeck",
            onStep: onStep
        )
    }

    init(
        cards: [HomeDeckCard],
        front: Int,
        selectedCategories: [String] = [],
        title: String,
        questionCount: Int,
        label: LocalizedStringKey,
        identifier: String,
        onStep: @escaping (CategoryCycle.Direction, CategoryStepInput) -> Void
    ) {
        self.cards = cards
        self.front = front
        self.selectedCategories = selectedCategories
        self.title = title
        self.questionCount = questionCount
        self.label = label
        self.identifier = identifier
        self.onStep = onStep
    }

    private var isMultiSelection: Bool { selectedCategories.count > 1 }

    var body: some View {
        VStack(spacing: Metrics.dotsGap) {
            ZStack {
                if isMultiSelection {
                    fan.transition(.opacity)
                } else {
                    HomeCategoryCycleCards(
                        cards: cards,
                        front: front,
                        questionCount: questionCount,
                        lift: lift
                    )
                    .transition(.opacity)
                }
                tapHalves
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Same footprint in both states so the pills below never shift.
            dots
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: title))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(.next, input: .voiceover)
            case .decrement: step(.previous, input: .voiceover)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Stepping

    /// The two halves: left = previous, right = next (canvas C1). Plain views,
    /// not buttons: VoiceOver gets the adjustable action instead.
    private var tapHalves: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(.rect)
                .onTapGesture { step(.previous) }
                .accessibilityIdentifier("\(identifier).previous")
            Color.clear.contentShape(.rect)
                .onTapGesture { step(.next) }
                .accessibilityIdentifier("\(identifier).next")
        }
    }

    /// Animate one step. The card that leaves (next) or arrives (previous)
    /// travels out to the side first and takes its place in the fan second —
    /// the C1 "card goes to the back" motion. Reduce Motion: a crossfade only.
    private func step(_ direction: CategoryCycle.Direction, input: CategoryStepInput = .tap) {
        liftTask?.cancel()
        if reduceMotion || isMultiSelection {
            withAnimation(.easeInOut(duration: Metrics.fadeDuration)) {
                lift = nil
                onStep(direction, input)
            }
            return
        }
        guard !cards.isEmpty else { return }
        let delta = direction == .next ? 1 : -1
        let current = cards[front].id
        let target = cards[(front + delta + cards.count) % cards.count].id
        let moving = direction == .next ? current : target
        // Springs, not timing curves: the settle spring is retargeted while the
        // card is still flying out and keeps its speed, so the two halves read
        // as one arc. An ease-out first half stopped the card dead at the side
        // before the second half pulled it back (stutter, founder 2026-11-16).
        withAnimation(.spring(duration: Metrics.outDuration, bounce: 0)) {
            lift = .init(id: moving, direction: direction)
            onStep(direction, input)
        }
        liftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Metrics.retargetDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: Metrics.settleDuration, bounce: 0.12)) { lift = nil }
        }
    }

    /// Page dots: where the front card sits in the cycle. Hidden while a
    /// multi-selection owns the deck (no single position).
    private var dots: some View {
        HangsPageIndicator(
            pageCount: cards.count,
            currentPage: front
        )
        .opacity(isMultiSelection ? 0 : 1)
        .frame(height: Metrics.dotsHeight)
    }

    // MARK: - Multi-selection fan (canvas C4)

    private var fan: some View {
        ZStack {
            ForEach(Array(backCards.enumerated()), id: \.element) { index, id in
                backCard(id)
                    .rotationEffect(Metrics.fan[index].angle, anchor: .bottom)
                    .offset(x: Metrics.fan[index].offset)
            }
            frontCard
                .rotationEffect(Metrics.frontAngle, anchor: .bottom)
        }
    }

    /// Three cards behind the front one: the selected categories nearest the
    /// front, topped up from the taxonomy so the fan always has three.
    private var backCards: [String] {
        let taxonomy = Theme.Hangs.Category.taxonomy
        let rest = Metrics.defaultFan.filter { !selectedCategories.contains($0) }
            + taxonomy.filter { !selectedCategories.contains($0) && !Metrics.defaultFan.contains($0) }
        let nearestFirst = Array((selectedCategories + rest).prefix(Metrics.fan.count))
        return nearestFirst.reversed()
    }

    private var stripCategories: [String] {
        selectedCategories.isEmpty ? Theme.Hangs.Category.taxonomy : selectedCategories
    }

    private func backCard(_ id: String) -> some View {
        let style = Theme.Hangs.Category.style(for: id)
        return Text(verbatim: Config.categoryDisplayName(for: id) ?? "")
            .textCase(.uppercase)
            .font(.hangsOverline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(style.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(Theme.Hangs.Spacing.md)
            .deckCardShape(fill: style.fill)
    }

    private var frontCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(questionCount) questions")
                .font(.hangsCaption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            Text(verbatim: title)
                .font(.hangsHeading)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            HStack(spacing: 0) {
                ForEach(stripCategories, id: \.self) { id in
                    Theme.Hangs.Category.style(for: id).fill
                }
            }
            .frame(height: Metrics.stripHeight)
            .clipShape(Capsule())
        }
        .foregroundStyle(Theme.Hangs.Colors.ink)
        .padding(Theme.Hangs.Spacing.md)
        .deckCardShape(fill: Theme.Hangs.Colors.bgCard)
    }

    private typealias Metrics = DeckMetrics
}

/// One card of the deck's cycle.
struct HomeDeckCard {
    let id: String
    let name: String
    /// The card's colours; nil = the white "All categories" card with the strip.
    let style: Theme.Hangs.Category.Style?

    /// All categories, then each category (`CategoryCycle.order`).
    static var categories: [HomeDeckCard] {
        Config.categoryOptions.map { option in
            HomeDeckCard(
                id: option.id ?? HomeCategoryCycleCards.allID,
                name: option.display,
                style: option.id.map { Theme.Hangs.Category.style(for: $0) }
            )
        }
    }

    /// #236: a band's topics, coloured round the category palette in list
    /// order so neighbours in the fan never share a colour.
    static func topics(_ topics: [FamilyTopic]) -> [HomeDeckCard] {
        let palette = Theme.Hangs.Category.taxonomy
        return topics.enumerated().map { index, topic in
            HomeDeckCard(
                id: topic.key,
                name: topic.name,
                style: Theme.Hangs.Category.style(for: palette[index % palette.count])
            )
        }
    }
}

enum DeckMetrics {
    static let dotsGap: CGFloat = 12
    static let dotsHeight: CGFloat = 8
    /// First half of a step: the moving card travels out to the side. The
    /// settle starts at `retargetDelay`, well before the out spring would come
    /// to rest, so the card turns around without stopping.
    static let outDuration = 0.4
    static let retargetDelay = 0.17
    static let settleDuration = 0.45
    static let fadeDuration = 0.2
    static let sideOffset: CGFloat = 98
    /// Canvas card ("lower fan", founder 2026-11-18): 146 × 186, ~30 % below
    /// the first 196 × 256, so more of Home fits above Start.
    static let cardSize = CGSize(width: 146, height: 186)
    static let stripHeight: CGFloat = 8
    static let frontAngle = Angle.degrees(2)
    /// Back to front: the canvas fan (rotation about the bottom edge, x shift).
    static let fan: [(angle: Angle, offset: CGFloat)] = [
        (.degrees(-13), -14),
        (.degrees(11), 14),
        (.degrees(-4), 0),
    ]
    static let defaultFan = ["geography-world", "science-nature", "history"]
}

extension View {
    /// One deck card: the canvas proportions, scaled to fit, on its fill with
    /// the raised shadow (on the plate only, so text stays crisp).
    func deckCardShape(fill: Color) -> some View {
        aspectRatio(DeckMetrics.cardSize, contentMode: .fit)
            .frame(maxWidth: DeckMetrics.cardSize.width, maxHeight: DeckMetrics.cardSize.height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                    .fill(fill)
                    .hangsShadow(Theme.Hangs.Shadow.raised)
            )
    }
}

#if DEBUG
    #Preview {
        VStack {
            HomeCategoryDeck(selectedCategories: [], title: "All Categories", questionCount: 10, onStep: { _, _ in })
            HomeCategoryDeck(selectedCategories: ["movies-music", "entertainment"], title: "2 selected", questionCount: 10, onStep: { _, _ in })
        }
        .padding(16)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
