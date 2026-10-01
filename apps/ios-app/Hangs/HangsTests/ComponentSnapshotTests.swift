//
//  ComponentSnapshotTests.swift
//  HangsTests
//
//  #188 track C: every shared component in `Views/Components`, frozen per state
//  as pixel snapshots. Hero screens (HeroScreenSnapshotTests) show a whole flow;
//  these show the building blocks one by one, and are the images the design
//  catalog on claude.ai is generated from (track D) — real SwiftUI, not a web
//  imitation.
//
//  Each sample renders three ways: dark and light at default text size, and dark
//  at accessibility Dynamic Type. Same runtime rules as the hero pixels: tied to
//  `SnapshotBaseline.iosVersion`, visibly skipped elsewhere, host settings pinned.
//
//  Not covered, on purpose: the pressed state (SwiftUI cannot force a
//  ButtonStyle's `isPressed` outside a real touch), open menus, and the
//  forever-animating voice glows (`AmbientGlowWash`, `GlowSweepLine`).
//
//  Baselines live in `__Snapshots__/ComponentSnapshotTests/`. Never re-record to
//  make a red run green; see `.claude/rules/ios.md`.
//

@testable import Hangs
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

/// One component in one state. `id` is `<component>.<state>` in lowerCamelCase
/// and doubles as the baseline file name, so keep it stable.
/// Nonisolated so `@Test(arguments:)` can list the ids; views are only built
/// inside `make`, on the main actor.
nonisolated struct ComponentSample {
    let id: String
    let make: @MainActor () -> AnyView

    init(_ id: String, @ViewBuilder _ make: @escaping @MainActor () -> some View) {
        self.id = id
        self.make = { @MainActor in AnyView(make()) }
    }

    static var all: [ComponentSample] { controls + quiz }

    /// Long Slovak copy — the language that wraps first.
    static let longSlovak = "Pokračovať bez odpovede a prejsť na ďalšiu otázku"
}

@Suite("Component snapshots")
@MainActor
struct ComponentSnapshotTests {
    @Test("ids are unique")
    func idsAreUnique() {
        // A duplicate id would silently overwrite another sample's baseline.
        let ids = ComponentSample.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test(
        "pixels",
        .enabled(if: SnapshotBaseline.runtimeMatches, "pixel baselines were recorded on iOS \(SnapshotBaseline.iosVersion); re-record on this runtime to enable them here"),
        arguments: ComponentSample.all.map(\.id)
    )
    func pixels(id: String) throws {
        let sample = try #require(ComponentSample.all.first { $0.id == id })
        for (scheme, size, suffix) in [
            (ColorScheme.dark, DynamicTypeSize.large, "dark"),
            (.light, .large, "light"),
            (.dark, .accessibility2, "dark-xl"),
        ] {
            assertSnapshot(of: framed(sample, scheme: scheme, size: size), as: strategy(scheme), named: "\(id)-\(suffix)")
        }
    }

    /// Phone content width on a page-coloured plate, everything the host could leak pinned.
    private func framed(_ sample: ComponentSample, scheme: ColorScheme, size: DynamicTypeSize) -> AnyView {
        AnyView(
            sample.make()
                .frame(width: SnapshotBaseline.width - 2 * Theme.Hangs.Spacing.md)
                .padding(Theme.Hangs.Spacing.md)
                .background(Theme.Hangs.Colors.bg)
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
                .dynamicTypeSize(size)
        )
    }

    private func strategy(_ scheme: ColorScheme) -> Snapshotting<AnyView, UIImage> {
        .image(
            precision: 0.99,
            perceptualPrecision: 0.98,
            layout: .sizeThatFits,
            traits: UITraitCollection(traitsFrom: [
                UITraitCollection(displayScale: 1),
                UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light),
                UITraitCollection(preferredContentSizeCategory: .large),
            ])
        )
    }
}
