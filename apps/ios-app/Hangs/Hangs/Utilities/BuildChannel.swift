//
//  BuildChannel.swift
//  Hangs
//
//  Which channel this build was installed from (#155). The TestFlight-only
//  tester surfaces (rating panel, review badges, voice diagnostics, answer
//  recording consent, the `X-Build-Channel` header) key off the receipt: a
//  TestFlight install carries a `sandboxReceipt`, an App Store install a
//  `receipt`. Development (`#if DEBUG`) counts as enabled so the surfaces are
//  reachable on the simulator.
//
//  #209: App Review installs with a sandbox receipt too, so the receipt alone
//  showed reviewers the tester surfaces (guideline 2.2). The build submitted
//  for review is compiled with the `APP_STORE` condition
//  (`APP_STORE_VARIANT=YES`, `ios-release.yml` input `store: true`): it never
//  counts as TestFlight, whatever its receipt says. Purchases do not read this
//  file; StoreKit/RevenueCat pick the sandbox environment on their own, so
//  App Review can still buy.
//
//  The receipt URL and both build flags are injectable so the predicates are
//  unit-testable without faking a real receipt or recompiling.
//

import Foundation

nonisolated enum BuildChannel {
    /// Compile-time channel flag. Local (not `Config.isDebug`) because that one
    /// is main-actor isolated and this predicate must stay callable anywhere.
    static let isDebugBuild: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    /// #209: the App Store variant (`APP_STORE` compilation condition). Wins
    /// over the receipt and over `DEBUG`.
    static let isAppStoreBuild: Bool = {
        #if APP_STORE
            return true
        #else
            return false
        #endif
    }()

    /// True when the app was installed via TestFlight. Always false in the
    /// App Store variant, so that build also uses the App Store minimum
    /// version and update link (`AppConfigStore`, `UpdateRequiredView`).
    static func isTestFlight(
        receiptURL: URL? = Bundle.main.appStoreReceiptURL,
        isAppStoreBuild: Bool = BuildChannel.isAppStoreBuild
    ) -> Bool {
        guard !isAppStoreBuild else { return false }
        return receiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Gate for TestFlight-only tester surfaces: a TestFlight install, OR any
    /// development build. The App Store variant always gets `false`.
    static func debugSurfacesEnabled(
        receiptURL: URL? = Bundle.main.appStoreReceiptURL,
        isDebugBuild: Bool = BuildChannel.isDebugBuild,
        isAppStoreBuild: Bool = BuildChannel.isAppStoreBuild
    ) -> Bool {
        guard !isAppStoreBuild else { return false }
        #if DEBUG
            // #190: store-screenshot mode renders the App Store look — no review
            // label, rating entry or diagnostics. Test processes never pass the flag.
            if CommandLine.arguments.contains("--store-screenshots") { return false }
        #endif
        return isDebugBuild || isTestFlight(receiptURL: receiptURL, isAppStoreBuild: false)
    }
}
