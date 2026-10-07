//
//  StoreManager+Analytics.swift
//  Hangs
//
//  #51: purchase and restore outcomes, read from the `purchaseState` each
//  attempt settled on — the same state the paywall renders.
//

extension StoreManager {
    /// The attempt's outcome as `purchaseState` settled it. `.activating` is a
    /// success: the money moved, only the server mirror is still catching up.
    func trackPurchaseResult(productID: String) {
        let outcome: PurchaseResultOutcome? = switch purchaseState {
        case .success, .activating: .success
        case .cancelled: .cancelled
        case .pending: .pending
        case .failed: .failed
        case .idle, .purchasing, .restoring, .nothingToRestore: nil
        }
        guard let outcome else { return }
        let kind: PurchaseKind = productID == StoreProduct.monthlySubId ? .subscription : .credits
        analytics.track(.purchaseResult(productId: productID, kind: kind, outcome: outcome))
    }

    func trackRestoreResult() {
        let outcome: RestoreOutcome? = switch purchaseState {
        case .success: .success
        case .nothingToRestore: .nothingToRestore
        case .failed: .failed
        case .idle, .purchasing, .restoring, .activating, .cancelled, .pending: nil
        }
        guard let outcome else { return }
        analytics.track(.restoreResult(outcome: outcome))
    }
}
