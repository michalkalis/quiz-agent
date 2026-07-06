//
//  HangsNavBar.swift
//  Hangs
//
//  Pinned-navigation-bar chrome for pushed screens (#80): brand back chip
//  (leading) and the interactive-pop re-enabler that custom back buttons need.
//  Design reference: Pencil NEW_Screen/Settings (Jjcs5) leading pill.
//

import SwiftUI
import UIKit

// MARK: - Brand back chip (leading toolbar item)

/// `← hangs. •` pill used as the leading back control on pushed screens.
/// Replaces the system back button visually while keeping HIG placement;
/// pair with `NavigationPopGestureEnabler` so edge-swipe keeps working.
struct HangsBackChip: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                HangsBrandMark(size: 15)
            }
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                Capsule(style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .hangsShadow(Theme.Hangs.Shadow.navChip)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Back"))
    }
}

// MARK: - Edge-swipe back re-enabler

/// Hiding the system back button (`.navigationBarBackButtonHidden`) also kills
/// the left-edge swipe-to-go-back gesture, and on iOS 26 SwiftUI's
/// NavigationStack no longer consults `interactivePopGestureRecognizer`'s
/// delegate (verified empirically — a replaced delegate is never asked), so
/// the classic delegate-override fix is dead. Instead this installs a pan
/// recognizer that only accepts touches starting in the left-edge strip and
/// performs the standard pop once the swipe is decisively horizontal and past
/// a threshold. The recognizer is removed when the host screen disappears, so
/// sibling screens keep their default behavior.
struct NavigationPopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> UIViewController { Controller() }
    func updateUIViewController(_: UIViewController, context _: Context) {}

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private weak var observedNav: UINavigationController?
        private weak var edgePan: UIPanGestureRecognizer?
        private var didTriggerPop = false

        /// Touches must start within this distance from the left screen edge.
        static let edgeWidth: CGFloat = 30
        /// Horizontal swipe distance (pt) that commits the pop — small enough
        /// to feel responsive, large enough that an edge graze does nothing.
        static let popThreshold: CGFloat = 60

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attachEdgePan()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Retry: inside SwiftUI the parent chain may not reach the
            // navigation controller yet at viewWillAppear time.
            attachEdgePan()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            if let pan = edgePan {
                pan.view?.removeGestureRecognizer(pan)
                edgePan = nil
            }
        }

        private func attachEdgePan() {
            guard edgePan == nil,
                  let nav = navigationController ?? parent?.navigationController else { return }
            observedNav = nav
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            nav.view.addGestureRecognizer(pan)
            edgePan = pan
        }

        @objc private func handleEdgePan(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                didTriggerPop = false
            case .changed:
                guard !didTriggerPop,
                      let nav = observedNav,
                      nav.viewControllers.count > 1,
                      nav.transitionCoordinator == nil else { return }
                let translation = pan.translation(in: pan.view)
                // Decisively horizontal, rightward, past the threshold —
                // a vertical scroll that happens to start at the edge stays a scroll.
                guard translation.x > Self.popThreshold,
                      translation.x > abs(translation.y) else { return }
                didTriggerPop = true
                nav.popViewController(animated: true)
            default:
                break
            }
        }

        /// Only touches that start in the left-edge strip feed this recognizer.
        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let view = gesture.view else { return false }
            return touch.location(in: view).x <= Self.edgeWidth
        }

        /// Let vertical scrolling that happens to start at the edge keep
        /// working (pans only) — taps stay exclusive, so once this pan begins
        /// the touch is cancelled for the content underneath and a swipe can
        /// never double-fire a row tap.
        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { other is UIPanGestureRecognizer }
    }
}

#if DEBUG
    #Preview {
        HangsBackChip {}
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
