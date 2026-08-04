//
//  PackPurchaseServiceTests.swift
//  HangsTests
//
//  #140: the pending-proof slot is the crash-recovery path for a PAID pack
//  purchase whose order POST never landed. Losing it (or reading back a
//  corrupted proof) silently eats the user's money — the store must round-trip
//  the proof exactly, and clear must actually forget it.
//

import Foundation
@testable import Hangs
import Testing

@Suite("PendingPackPurchaseStore (#140)")
struct PendingPackPurchaseStoreTests {
    /// An isolated, wiped defaults suite so tests never see (or leave behind)
    /// a real pending proof in the app's standard defaults.
    private func makeStore() -> PendingPackPurchaseStore {
        let suiteName = "PendingPackPurchaseStoreTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        return PendingPackPurchaseStore(suiteName: suiteName)
    }

    @Test("a saved proof loads back exactly — transaction id, product id, and JWS")
    func roundTrip() {
        let store = makeStore()
        let proof = PackPaymentProof(
            transactionId: "990000000000123",
            productId: "pack_30",
            jws: "header.payload.signature"
        )

        store.save(proof)

        #expect(store.load() == proof)
    }

    @Test("an empty store loads nil — no phantom pending purchase")
    func emptyLoadsNil() {
        #expect(makeStore().load() == nil)
    }

    @Test("clear forgets the proof — a spent purchase must not replay into the next order")
    func clearForgets() {
        let store = makeStore()
        store.save(PackPaymentProof(transactionId: "1", productId: "pack_30", jws: "a.b.c"))

        store.clear()

        #expect(store.load() == nil)
    }
}
