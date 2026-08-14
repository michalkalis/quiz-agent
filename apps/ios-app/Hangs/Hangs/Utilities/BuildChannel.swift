//
//  BuildChannel.swift
//  Hangs
//
//  Which channel this build was installed from (#155). The in-app question
//  rating panel is a TestFlight-only debug surface — it must never appear in an
//  App Store build — so the gate is a runtime receipt check, not a build flag:
//  a TestFlight install carries a `sandboxReceipt`, an App Store install a
//  `receipt`. Development (`#if DEBUG`) counts as enabled so the panel is
//  reachable on the simulator.
//
//  The receipt URL is injectable so the predicate is unit-testable without
//  faking a real receipt.
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

    /// True when the app was installed via TestFlight.
    static func isTestFlight(receiptURL: URL? = Bundle.main.appStoreReceiptURL) -> Bool {
        receiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Gate for TestFlight-only debug surfaces (#155 rating panel): a TestFlight
    /// install, OR any development build. App Store builds get `false`.
    static func debugSurfacesEnabled(
        receiptURL: URL? = Bundle.main.appStoreReceiptURL,
        isDebugBuild: Bool = BuildChannel.isDebugBuild
    ) -> Bool {
        isDebugBuild || isTestFlight(receiptURL: receiptURL)
    }
}
