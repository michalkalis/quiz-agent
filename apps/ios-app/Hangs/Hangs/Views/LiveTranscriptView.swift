//
//  LiveTranscriptView.swift
//  Hangs
//
//  Animated word-by-word transcript display for streaming STT
//

import Combine
import SwiftUI

/// Displays streaming transcript with word-by-word fade-in animation.
/// Each new word slides up and fades in with staggered timing.
struct LiveTranscriptView: View {
    let text: String
    let isCommitted: Bool

    @State private var visibleCount: Int = 0
    @State private var lastWordCount: Int = 0

    private var words: [String] {
        text.split(separator: " ").map(String.init)
    }

    var body: some View {
        Group {
            if text.isEmpty && !isCommitted {
                ListeningPlaceholder()
            } else {
                WrappingHStack(words: words, visibleCount: visibleCount, isCommitted: isCommitted)
            }
        }
            .onChange(of: text) { _, newValue in
                let newWords = newValue.split(separator: " ")
                let newCount = newWords.count

                if newCount > lastWordCount {
                    // Animate new words in with stagger
                    let previousCount = lastWordCount
                    lastWordCount = newCount

                    for i in previousCount..<newCount {
                        let delay = Double(i - previousCount) * 0.05
                        withAnimation(.easeOut(duration: 0.2).delay(delay)) {
                            visibleCount = i + 1
                        }
                    }
                } else {
                    // Text shortened (new partial) — reset
                    lastWordCount = newCount
                    visibleCount = newCount
                }
            }
            .onAppear {
                // Show all existing words immediately on appear
                let count = words.count
                lastWordCount = count
                visibleCount = count
            }
    }
}

// MARK: - Listening Placeholder

/// Three pulsing dots shown while STT is connected but no words have arrived yet.
/// Keeps the LISTENING card from looking empty during the brief pause between
/// "user tapped mic" and "first partial transcript arrives".
private struct ListeningPlaceholder: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.Colors.textPrimary.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.35)
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }
        }
        .frame(height: 18, alignment: .leading)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Wrapping Layout

/// Simple wrapping horizontal layout for words
private struct WrappingHStack: View {
    let words: [String]
    let visibleCount: Int
    let isCommitted: Bool

    var body: some View {
        // Use a flexible flow layout via ViewThatFits alternative
        // For simplicity and reliability, use a multiline Text approach
        // that still supports per-word animation
        FlowLayout(spacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(isCommitted ? .textMDMedium : .textMDBodyMedium)
                    .foregroundColor(isCommitted ? Theme.Colors.accentPrimary : Theme.Colors.textPrimary)
                    .opacity(index < visibleCount ? 1 : 0)
                    .offset(y: index < visibleCount ? 0 : 6)
            }
        }
    }
}

// MARK: - Flow Layout

/// A simple flow layout that wraps items to the next line
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let position = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                // Wrap to next line
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}

#Preview {
    VStack(spacing: 20) {
        LiveTranscriptView(text: "", isCommitted: false)
            .padding()
            .background(Theme.Colors.bgCard.opacity(0.8))
            .cornerRadius(Theme.Radius.lg)

        LiveTranscriptView(text: "This is a test of the word by word animation", isCommitted: false)
            .padding()
            .background(Theme.Colors.bgCard.opacity(0.8))
            .cornerRadius(Theme.Radius.lg)

        LiveTranscriptView(text: "Final committed answer", isCommitted: true)
            .padding()
            .background(Theme.Colors.bgCard.opacity(0.8))
            .cornerRadius(Theme.Radius.lg)
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
