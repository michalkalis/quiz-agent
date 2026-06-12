//
//  AdaptiveColorIsolationTests.swift
//  HangsTests
//
//  #54 task 54.7 — onboarding Continue crashed the app (SIGTRAP in
//  dispatch_assert_queue_fail). With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor,
//  the dynamicProvider closure inside Color(light:dark:) was inferred
//  MainActor-isolated; iOS 26 SwiftUI resolves dynamic colors on its async
//  render thread during animated transitions, tripping the executor check.
//  This test resolves the adaptive tokens off-main — it crashes the process
//  if the closure ever regains an actor isolation tag.
//

import Testing
import SwiftUI
import UIKit
@testable import Hangs

struct AdaptiveColorIsolationTests {

    @Test @MainActor
    func adaptiveTokensResolveOffMainWithoutTrapping() async {
        // Bridge on main (as views do), resolve off main (as renderAsync does).
        let colors = [
            UIColor(Theme.Hangs.Colors.bg),
            UIColor(Theme.Hangs.Colors.bgCard),
            UIColor(Theme.Hangs.Colors.ink),
            UIColor(Color(light: "#FFFFFF", dark: "#1F1F22")),
            UIColor(Color(light: Color.white, dark: Color.black)),
        ]
        let resolved = await Task.detached { () -> [UIColor] in
            var out: [UIColor] = []
            for color in colors {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    out.append(color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
                }
            }
            return out
        }.value
        #expect(resolved.count == colors.count * 2)
    }
}
