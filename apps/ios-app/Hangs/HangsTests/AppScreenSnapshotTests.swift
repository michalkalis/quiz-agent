//
//  AppScreenSnapshotTests.swift
//  HangsTests
//
//  #194 phase A2: pixel + text-contract coverage for the screens the hero suite
//  does not freeze — Settings, Onboarding (all four pages), Completion (with and
//  without the upsell card), the set recap, the answer confirmation sheet, the
//  order-pack flow, the contextual sign-in sheet and the error screen. The
//  redesign (#194, "Sklo nad kartami") restyles every one of them; a baseline
//  here is what lets each redesign PR show a before/after and catch a layout
//  change nobody meant.
//
//  Same machinery and rules as `HeroScreenSnapshotTests` (read its header):
//  the text contract gates every CI run, pixels (1x, dark, default + accessibility
//  Dynamic Type, sk/cs/en) run only on `SnapshotBaseline.iosVersion`, host
//  appearance / text size / locale are pinned on the view, and a diff is
//  re-recorded on purpose after a human looked at it — never to turn a run green.
//
//  Baselines live in `__Snapshots__/AppScreenSnapshotTests/`.
//  The screen builders are in `AppScreen+Quiz.swift` and `AppScreen+Flows.swift`.
//

import Foundation
@testable import Hangs
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import ViewInspector

/// The screens, each in one fixed, settled state. Raw values are baseline file
/// names — keep them stable.
@MainActor
enum AppScreen: String, CaseIterable {
    case settings
    case onboardingWelcome, onboardingFeatures, onboardingPermission, onboardingDenied
    case completion, completionUpsell
    case setRecap
    case confirmTranscribing, confirmTranscript
    case orderForm, orderSummary, orderPreparing, orderReadyGenerating, orderReady, orderFailed
    case signInIdle, signInSigningIn, signInFailed
    case errorRetry, errorGoHome, errorDismiss
    case paywallPack, paywallOffline
    case homeCredits, homeSubscriber, homeGrace, homeExpired, homePacks, homeCategories

    /// Settings is a long scroll view; a device-height frame would freeze only its
    /// first screenful, so it renders on a tall canvas instead — tall enough for
    /// Voice through Subscription, and cut before About, whose Version row changes
    /// with every release bump.
    var height: CGFloat {
        self == .settings ? 1850 : SnapshotBaseline.height
    }
}

// MARK: - Determinism

// MARK: - Text contract

/// Every rendered Text (resolved for `language`) and every accessibility
/// identifier, in tree order — see `HeroScreenSnapshotTests` for why.
@MainActor
private func buildTextContract(of screen: AppScreen, in language: HeroLanguage) async throws -> String {
    let view = await screen.make()
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var lines: [String] = ["# texts"]
    try await ViewHosting.host(view, function: "\(screen.rawValue)-\(language.rawValue)") {
        let tree = try view.inspect()
        for text in tree.findAll(ViewType.Text.self) {
            guard let value = try? text.string(locale: language.locale) else { continue }
            // The app version changes with every release bump; it is not layout.
            if value == version { continue }
            // Settings: the voice-diagnostics group and everything below it is
            // built from the host's audio route and file system (and the Debug-only
            // developer group), so it is not part of the stable, shipped screen.
            // The sentinel is the English source key, so test it in English — the
            // label is translated in sk/cs.
            if screen == .settings,
               (try? text.string(locale: HeroLanguage.en.locale)) == "voice diagnostics" { break }
            lines.append(value)
        }
        lines.append("# identifiers")
        for node in tree.findAll(where: { (try? $0.accessibilityIdentifier()) != nil }) {
            if let id = try? node.accessibilityIdentifier() {
                if screen == .settings, id == "settings-voice-processing-toggle" { break }
                lines.append(id)
            }
        }
    }
    return lines.joined(separator: "\n")
}

@Suite("App screen snapshots")
@MainActor
struct AppScreenSnapshotTests {
    @Test("text contract", arguments: AppScreen.allCases, HeroLanguage.allCases)
    func textContract(screen: AppScreen, language: HeroLanguage) async throws {
        let contract = try await buildTextContract(of: screen, in: language)
        assertSnapshot(of: contract, as: .lines, named: "\(screen.rawValue)-\(language.rawValue)")
    }

    @Test(
        "pixels",
        .enabled(if: SnapshotBaseline.runtimeMatches, "pixel baselines were recorded on iOS \(SnapshotBaseline.iosVersion); re-record on this runtime to enable them here"),
        arguments: AppScreen.allCases, HeroLanguage.allCases
    )
    func pixels(screen: AppScreen, language: HeroLanguage) async {
        // Pinned, not inherited — same as the hero suite (dark, 1x, fixed locale).
        let view = await screen.make()
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
        let strategy: Snapshotting<AnyView, UIImage> = .image(
            precision: 0.99,
            perceptualPrecision: 0.98,
            layout: .fixed(width: SnapshotBaseline.width, height: screen.height),
            traits: UITraitCollection(traitsFrom: [
                UITraitCollection(displayScale: 1),
                UITraitCollection(userInterfaceStyle: .dark),
                UITraitCollection(preferredContentSizeCategory: .large),
            ])
        )
        assertSnapshot(
            of: AnyView(view.dynamicTypeSize(.large)),
            as: strategy,
            named: "\(screen.rawValue)-\(language.rawValue)"
        )
        assertSnapshot(
            of: AnyView(view.dynamicTypeSize(.accessibility2)),
            as: strategy,
            named: "\(screen.rawValue)-\(language.rawValue)-xl"
        )
        // #194 B: the redesign is light-first, so the default size is frozen in
        // light too (the dark pair above stays; layout does not depend on it).
        let light = await screen.make()
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.colorScheme, .light)
            .preferredColorScheme(.light)
        assertSnapshot(
            of: AnyView(light.dynamicTypeSize(.large)),
            as: .image(
                precision: 0.99,
                perceptualPrecision: 0.98,
                layout: .fixed(width: SnapshotBaseline.width, height: screen.height),
                traits: UITraitCollection(traitsFrom: [
                    UITraitCollection(displayScale: 1),
                    UITraitCollection(userInterfaceStyle: .light),
                    UITraitCollection(preferredContentSizeCategory: .large),
                ])
            ),
            named: "\(screen.rawValue)-\(language.rawValue)-light"
        )
    }
}
