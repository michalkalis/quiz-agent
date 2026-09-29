//
//  InteractiveMinimizeModifier.swift
//  Hangs
//
//  Reusable view modifier for interactive pull-down-to-minimize gesture
//
//  #189 (founder feedback 2026-09-29): the offset used to live in `@State`, set
//  in `onChanged` and cleared only in `onEnded`. Pulling down Control Center (or
//  any system gesture that steals the touch) CANCELS the drag gesture without
//  ever calling `onEnded`, so the offset stayed latched and the question screen
//  stayed shifted/scaled/faded. `@GestureState` resets to its initial value on
//  ANY end of the gesture — normal release or cancellation — so the fix is to
//  keep the offset there instead: `onEnded` now only decides whether to
//  minimize, never the snap-back.
//

import SwiftUI

struct InteractiveMinimizeModifier: ViewModifier {
    @Binding var isMinimized: Bool
    let canMinimize: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var dragOffset: CGFloat = 0

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
                    .updating($dragOffset) { value, state, transaction in
                        // The transaction SwiftUI uses to animate `state` back to
                        // its initial value (0) once the gesture ends OR is
                        // cancelled — set on every update so it is always current
                        // for whichever happens. Reduce Motion-aware, same as the
                        // old explicit snap-back animations were.
                        transaction.animation = reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)

                        guard canMinimize else { return }
                        let translation = value.translation.height

                        // Only track downward drags
                        if translation > 0 {
                            // Apply rubber-banding: diminishing returns as you drag further
                            // sqrt gives a nice deceleration curve
                            state = sqrt(translation) * 8
                        }
                    }
                    .onEnded { value in
                        guard canMinimize else { return }

                        let translation = value.translation.height
                        let velocity = value.predictedEndTranslation.height - translation

                        // Check if we should minimize:
                        // 1. Dragged past threshold, OR
                        // 2. Fast flick (velocity > threshold)
                        let shouldMinimize = translation > minimizeThreshold
                            || (translation > 50 && velocity > velocityThreshold)

                        // Not minimizing: `@GestureState` snaps `dragOffset` back
                        // to 0 on its own, via the transaction set in `updating`.
                        if shouldMinimize {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) {
                                isMinimized = true
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
