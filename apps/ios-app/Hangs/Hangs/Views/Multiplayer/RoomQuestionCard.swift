//
//  RoomQuestionCard.swift
//  Hangs
//
//  #224.4: the question card of a game together. It takes the room the
//  options leave free, shows no scroll bar and, like the solo screen, lets a
//  long question drift to its end at reading pace. The host's card replays the
//  question on a tap; a guest has no audio controls.
//

import SwiftUI

struct RoomQuestionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let question: Question
    let isHost: Bool
    /// Host: the phone may read the question again (reading is on, not playing).
    let canReplay: Bool
    /// Guest: the host's phone is reading the question aloud right now.
    let hostIsReading: Bool
    let replay: () -> Void

    @State private var scroll = ScrollPosition()
    @State private var overflow: CGFloat = 0

    var body: some View {
        let identity = DeckIdentity(category: question.category, packId: nil)
        HangsDeckCard(
            style: identity.style,
            categoryName: identity.chipName,
            categoryIdentifier: "question.category",
            accessory: { accessory }
        ) {
            ScrollView {
                Text(question.question)
                    .font(.hangsTitle)
                    .minimumScaleFactor(Metrics.minScale)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("question.text")
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentSize.height - geometry.containerSize.height)
            } action: { _, new in
                overflow = new
            }
            .task(id: question.id) { await drift() }
            // a11y-id: the speaker button in the card header is the accessible "read again"
            .onTapGesture { if isHost, canReplay { replay() } }
        }
        .frame(minHeight: Metrics.minHeight)
    }

    @ViewBuilder
    private var accessory: some View {
        if isHost {
            Button(action: replay) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.hangsBody(Metrics.iconSize, weight: .semibold))
                    .frame(width: Metrics.buttonSide, height: Metrics.buttonSide)
            }
            .buttonStyle(.plain)
            .disabled(!canReplay)
            .opacity(canReplay ? 1 : Metrics.dimmed)
            .accessibilityLabel(Text("Read again"))
            .accessibilityIdentifier("room.readAgain")
        } else if hostIsReading {
            Label("The host is reading aloud", systemImage: "speaker.wave.2")
                .font(.hangsCaption)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(Metrics.minScale)
                .accessibilityIdentifier("room.question.reading")
        }
    }

    /// Same pacing as the solo screen: a beat on the top, then a slow drift.
    private func drift() async {
        scroll.scrollTo(edge: .top)
        guard !reduceMotion else { return }
        try? await Task.sleep(for: QuestionStemAutoScroll.readingBeat)
        guard !Task.isCancelled, overflow > 0 else { return }
        withAnimation(.linear(duration: QuestionStemAutoScroll.driftDuration(overflow: overflow))) {
            scroll.scrollTo(edge: .bottom)
        }
    }

    private enum Metrics {
        static let minHeight: CGFloat = 150
        static let minScale: CGFloat = 0.7
        static let iconSize: CGFloat = 16
        static let buttonSide: CGFloat = 44
        static let dimmed = 0.4
    }
}
