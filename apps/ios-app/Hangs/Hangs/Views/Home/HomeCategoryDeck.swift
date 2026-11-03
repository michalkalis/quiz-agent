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

import SwiftUI

struct HomeCategoryDeck: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Selected category ids; empty = all categories.
    let selectedCategories: [String]
    /// The front card's title: the same value the Categories pill shows.
    let title: String
    let questionCount: Int
    /// A tap on the left / right half (or VoiceOver decrement / increment).
    let onStep: (CategoryCycle.Direction, CategoryStepInput) -> Void

    @State private var lift: HomeCategoryCycleCards.Lift?
    @State private var liftTask: Task<Void, Never>?

    private var isMultiSelection: Bool { selectedCategories.count > 1 }

    var body: some View {
        VStack(spacing: Metrics.dotsGap) {
            ZStack {
                if isMultiSelection {
                    fan.transition(.opacity)
                } else {
                    HomeCategoryCycleCards(
                        front: CategoryCycle.position(of: selectedCategories),
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
        .accessibilityLabel(Text("Categories"))
        .accessibilityValue(Text(verbatim: title))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(.next, input: .voiceover)
            case .decrement: step(.previous, input: .voiceover)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("home.categoryDeck")
    }

    // MARK: - Stepping

    /// The two halves: left = previous, right = next (canvas C1). Plain views,
    /// not buttons: VoiceOver gets the adjustable action instead.
    private var tapHalves: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(.rect)
                .onTapGesture { step(.previous) }
                .accessibilityIdentifier("home.categoryDeck.previous")
            Color.clear.contentShape(.rect)
                .onTapGesture { step(.next) }
                .accessibilityIdentifier("home.categoryDeck.next")
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
        let order = CategoryCycle.order
        let current = order[CategoryCycle.position(of: selectedCategories, in: order)]
        let target = CategoryCycle.stepped(from: selectedCategories, direction, in: order).first
        let moving = direction == .next ? current : target
        withAnimation(.timingCurve(0.3, 0.7, 0.2, 1, duration: Metrics.outDuration)) {
            lift = .init(id: moving ?? HomeCategoryCycleCards.allID, direction: direction)
            onStep(direction, input)
        }
        liftTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Metrics.outDuration))
            guard !Task.isCancelled else { return }
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: Metrics.settleDuration)) { lift = nil }
        }
    }

    /// Page dots: where the front card sits in the cycle. Hidden while a
    /// multi-selection owns the deck (no single position).
    private var dots: some View {
        HangsPageIndicator(
            pageCount: CategoryCycle.order.count,
            currentPage: CategoryCycle.position(of: selectedCategories)
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
            .padding(Theme.Hangs.Spacing.lg)
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
                .font(.hangsTitle)
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
        .padding(Theme.Hangs.Spacing.lg)
        .deckCardShape(fill: Theme.Hangs.Colors.bgCard)
    }

    private typealias Metrics = DeckMetrics
}

enum DeckMetrics {
    static let dotsGap: CGFloat = 18
    static let dotsHeight: CGFloat = 8
    /// First half of a step: the moving card travels out to the side.
    static let outDuration = 0.27
    static let settleDuration = 0.3
    static let fadeDuration = 0.2
    static let sideOffset: CGFloat = 132
    /// Canvas card: 196 × 256, scaled down to the space Home has left.
    static let cardSize = CGSize(width: 196, height: 256)
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
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cta, style: .continuous)
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
