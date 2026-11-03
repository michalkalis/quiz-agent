//
//  HomeCategoryCycleCards.swift
//  Hangs
//
//  #224.6 (canvas C1) — one card per stop of the category cycle (All, then
//  each category), fanned by distance from the front card. A step moves the
//  front card out to the side and behind the fan (next) or brings the card
//  from the back out in front (previous); `HomeCategoryDeck` drives that
//  with `lift`. With Reduce Motion every card sits in the front slot and
//  only fades.
//

import SwiftUI

struct HomeCategoryCycleCards: View {
    /// A card travelling out to the side mid-step.
    struct Lift: Equatable {
        let id: String
        let direction: CategoryCycle.Direction
    }

    static let allID = "all"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Index of the front card in `CategoryCycle.order`.
    let front: Int
    let questionCount: Int
    let lift: Lift?

    var body: some View {
        let options = Config.categoryOptions
        ZStack {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let id = option.id ?? Self.allID
                let pose = pose(for: index, id: id, count: options.count)
                card(id: id, name: option.display, isFront: index == front)
                    .rotationEffect(pose.angle, anchor: .bottom)
                    .offset(x: pose.offset)
                    .opacity(pose.opacity)
                    .zIndex(pose.z)
            }
        }
    }

    // MARK: - Poses

    struct Pose: Equatable {
        var angle: Angle
        var offset: CGFloat
        var z: Double
        var opacity: Double
    }

    /// Front, then the canvas fan behind it; every further card waits hidden at
    /// the back of the fan.
    private static let slots: [Pose] = [
        Pose(angle: .degrees(2), offset: 0, z: 6, opacity: 1),
        Pose(angle: .degrees(-4), offset: 0, z: 5, opacity: 1),
        Pose(angle: .degrees(11), offset: 14, z: 4, opacity: 1),
        Pose(angle: .degrees(-13), offset: -14, z: 3, opacity: 1),
    ]
    private static let hidden = Pose(angle: .degrees(-13), offset: -14, z: 1, opacity: 0)

    private func pose(for index: Int, id: String, count: Int) -> Pose {
        let distance = (index - front + count) % count
        if reduceMotion {
            var frontSlot = Self.slots[0]
            frontSlot.opacity = distance == 0 ? 1 : 0
            frontSlot.z = distance == 0 ? 6 : 0
            return frontSlot
        }
        if let lift, lift.id == id {
            switch lift.direction {
            case .next:
                return Pose(angle: .degrees(15), offset: DeckMetrics.sideOffset, z: 20, opacity: 1)
            case .previous:
                return Pose(angle: .degrees(-15), offset: -DeckMetrics.sideOffset, z: 0, opacity: 1)
            }
        }
        return distance < Self.slots.count ? Self.slots[distance] : Self.hidden
    }

    // MARK: - Card

    /// The front card names the round (title, question count, colour strip for
    /// All); the cards behind carry the category as an overline only.
    private func card(id: String, name: String, isFront: Bool) -> some View {
        let isAll = id == Self.allID
        let style = isAll ? nil : Theme.Hangs.Category.style(for: id)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Text(verbatim: name)
                    .textCase(.uppercase)
                    .font(.hangsOverline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(isFront ? 0 : 1)
                Text("\(questionCount) questions")
                    .font(.hangsCaption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(isFront ? 1 : 0)
            }
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            Text(verbatim: name)
                .font(.hangsTitle)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .opacity(isFront ? 1 : 0)
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            if isAll {
                HStack(spacing: 0) {
                    ForEach(Theme.Hangs.Category.taxonomy, id: \.self) { id in
                        Theme.Hangs.Category.style(for: id).fill
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())
                .opacity(isFront ? 1 : 0)
            }
        }
        .foregroundStyle(style?.text ?? Theme.Hangs.Colors.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Hangs.Spacing.lg)
        .deckCardShape(fill: style?.fill ?? Theme.Hangs.Colors.bgCard)
        .animation(.easeInOut(duration: 0.3), value: isFront)
    }
}
