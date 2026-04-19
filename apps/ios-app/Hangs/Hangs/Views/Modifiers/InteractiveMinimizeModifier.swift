//
//  InteractiveMinimizeModifier.swift
//  Hangs
//
//  Reusable view modifier for interactive pull-down-to-minimize gesture
//

import SwiftUI

struct InteractiveMinimizeModifier: ViewModifier {
    @Binding var isMinimized: Bool
    let canMinimize: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    // Thresholds for triggering minimize
    private let minimizeThreshold: CGFloat = 150
    private let velocityThreshold: CGFloat = 500

    // Visual feedback limits
    private let maxOpacityReduction: CGFloat = 0.3
    private let maxScaleReduction: CGFloat = 0.05

    func body(content: Content) -> some View {
        content
            .offset(y: dragOffset)
            .opacity(1.0 - (dragOffset / 400).clamped(to: 0 ... maxOpacityReduction))
            .scaleEffect(1.0 - (dragOffset / 2000).clamped(to: 0 ... maxScaleReduction))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard canMinimize else { return }
                        let translation = value.translation.height

                        // Only track downward drags
                        if translation > 0 {
                            // Apply rubber-banding: diminishing returns as you drag further
                            // sqrt gives a nice deceleration curve
                            dragOffset = sqrt(translation) * 8
                        }
                    }
                    .onEnded { value in
                        guard canMinimize else {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                            return
                        }

                        let translation = value.translation.height
                        let velocity = value.predictedEndTranslation.height - translation

                        // Check if we should minimize:
                        // 1. Dragged past threshold, OR
                        // 2. Fast flick (velocity > threshold)
                        let shouldMinimize = translation > minimizeThreshold
                            || (translation > 50 && velocity > velocityThreshold)

                        if shouldMinimize {
                            // Animate minimize
                            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                                isMinimized = true
                                dragOffset = 0
                            }
                        } else {
                            // Snap back to original position
                            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
    }
}

// MARK: - View Extension

extension View {
    func interactiveMinimize(isMinimized: Binding<Bool>, canMinimize: Bool) -> some View {
        modifier(InteractiveMinimizeModifier(isMinimized: isMinimized, canMinimize: canMinimize))
    }
}

// MARK: - Comparable Extension

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
