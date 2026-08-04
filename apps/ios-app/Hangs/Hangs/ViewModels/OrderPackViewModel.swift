//
//  OrderPackViewModel.swift
//  Hangs
//
//  Drives the custom-pack order form + delivery poll (issue #95). Pays for the
//  pack via StoreKit (issue #140), creates an order via PackOrderService with
//  the purchase proof, then polls `getOrder` at 1 Hz until the order is
//  terminal (delivered / failed / refunded), publishing each step so the
//  progress view can render it. The poll task is cancelled on stop()/deinit.
//
//  Payment rules (#140): a durably-pending proof (paid, but the order POST
//  never landed) is always spent before a new charge is made, and the proof is
//  cleared only after the backend accepts the order. In Debug builds a stored
//  admin key skips payment entirely — the internal testing door.
//

import Combine
import Foundation
import os

@MainActor
final class OrderPackViewModel: ObservableObject {
    /// Form + delivery lifecycle. `Equatable` so SwiftUI can diff transitions
    /// (mirrors StoreManager.PurchaseState).
    enum OrderState: Equatable {
        case editing
        case submitting
        case polling(OrderSnapshot)
        case delivered(OrderSnapshot)
        case failed(String)
    }

    // Prompt bounds enforced client-side to match the server (422 otherwise).
    static let minPromptLength = 10
    static let maxPromptLength = 1000

    /// Consecutive `getOrder` failures tolerated before the poll gives up with
    /// `.failed`. A transient network/timeout blip on cellular must NOT dead-end a
    /// paid order that is still generating server-side — a false failure strands
    /// the user and invites a re-order / double charge. Only a run of errors longer
    /// than this is treated as a real, fatal failure.
    static let maxConsecutivePollErrors = 5

    /// Wall-clock budget for the foreground delivery poll, in seconds. Generation
    /// can outlive this (a suspended prod worker waking on the first order after
    /// idle, a dropped job); once the budget is spent we stop spinning and send the
    /// user to My packs rather than poll forever. Instance-settable so tests can
    /// exercise the timeout without waiting the full three minutes.
    var pollTimeoutSeconds: TimeInterval = 180

    /// Delay between poll iterations (and between retries after a transient error),
    /// in seconds — the ~1 Hz cadence. Instance-settable so timing tests don't wait
    /// on real time.
    var pollIntervalSeconds: TimeInterval = 1

    // MARK: Form fields

    @Published var prompt: String = ""
    @Published var language: String = "en"
    @Published var category: String = ""
    @Published var theme: String = ""

    @Published private(set) var state: OrderState = .editing

    private let service: PackOrderServiceProtocol
    private let purchaseService: PackPurchaseServiceProtocol
    /// Whether the Debug admin door is open (a key is stored). Injected so unit
    /// tests aren't at the mercy of the simulator's persistent Keychain; only
    /// consulted in Debug builds.
    private let adminKeyAvailable: () -> Bool
    private var pollTask: Task<Void, Never>?

    /// The intent behind the order currently being submitted (or last failed).
    /// Kept alive across a retry of the SAME form content so `createOrder`
    /// reuses the same idempotency key rather than minting a new one on every
    /// call (issue #103 finding 6a) — cleared once the create succeeds, since
    /// a later submit with the same content is then a genuinely new order.
    private var pendingIntent: PackOrderIntent?

    init(
        service: PackOrderServiceProtocol,
        purchaseService: PackPurchaseServiceProtocol = StoreKitPackPurchaseService(),
        adminKeyAvailable: @escaping () -> Bool = { AdminKeyStore().load() != nil }
    ) {
        self.service = service
        self.purchaseService = purchaseService
        self.adminKeyAvailable = adminKeyAvailable
    }

    deinit {
        pollTask?.cancel()
    }

    /// True when the trimmed prompt is within the server-accepted bounds.
    var isValid: Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Self.minPromptLength...Self.maxPromptLength).contains(trimmed.count)
    }

    /// Live character count of the trimmed prompt (for the counter UI).
    var trimmedPromptCount: Int {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    // MARK: Actions

    /// Create the order and poll to completion. Awaits the full lifecycle so a
    /// caller (or test) can inspect the terminal `state` afterwards; the running
    /// work is also held in `pollTask` so `stop()`/`deinit` can cancel it.
    func submit() async {
        guard isValid else { return }
        state = .submitting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runOrder()
        }
        pollTask = task
        await task.value
    }

    /// Cancel any in-flight polling (e.g. the user leaves the screen).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Internal

    private func runOrder() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTheme = theme.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCategory = trimmedCategory.isEmpty ? nil : trimmedCategory
        let resolvedTheme = trimmedTheme.isEmpty ? nil : trimmedTheme

        // #140: settle payment BEFORE the order is formed. A cancelled sheet or
        // a failed charge never reaches the backend.
        let proof: PackPaymentProof?
        do {
            proof = try await resolvePaymentProof()
        } catch {
            state = .failed(Self.message(for: error))
            return
        }

        // Reuse the pending intent (and its idempotency key) when the form
        // content is unchanged from the last attempt — a retry after a failed
        // submit (e.g. "Back" then "Create pack" again with the same fields).
        // Any change to the fields is a genuinely new intent, so it mints a
        // fresh key rather than reusing a stale one.
        let intent: PackOrderIntent
        if let pending = pendingIntent,
           pending.prompt == trimmedPrompt,
           pending.language == language,
           pending.category == resolvedCategory,
           pending.theme == resolvedTheme,
           pending.paymentProof == proof {
            intent = pending
        } else {
            intent = PackOrderIntent(
                prompt: trimmedPrompt,
                language: language,
                category: resolvedCategory,
                theme: resolvedTheme,
                paymentProof: proof
            )
        }
        pendingIntent = intent

        let created: OrderCreatedResponse
        do {
            created = try await service.createOrder(intent: intent)
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        pendingIntent = nil // order created — a future submit is a new order
        if intent.paymentProof != nil {
            // The backend accepted the order — the purchase is spent. (Guarded
            // so a Debug admin order can never discard a real unspent proof.)
            purchaseService.clearPendingProof()
        }

        await poll(orderId: created.orderId)
    }

    /// How this order gets paid: Debug builds with a stored admin key skip
    /// payment (nil proof → `X-Admin-Key` path); otherwise a durably-pending
    /// proof from an earlier interrupted attempt is spent first, and only when
    /// none exists does the App Store payment sheet run.
    private func resolvePaymentProof() async throws -> PackPaymentProof? {
        #if DEBUG
            if adminKeyAvailable() { return nil }
        #endif
        if let pending = purchaseService.pendingProof() {
            return pending
        }
        return try await purchaseService.purchase()
    }

    private func poll(orderId: String) async {
        let deadline = Date().addingTimeInterval(pollTimeoutSeconds)
        var consecutiveErrors = 0

        while !Task.isCancelled {
            // Overall timeout: an order wedged in in_progress — a suspended worker
            // that never woke, a dropped job — would otherwise poll at 1 Hz forever
            // and never resolve the "Building your pack…" spinner. Stop and hand the
            // user off to My packs; any generation still runs server-side.
            if Date() >= deadline {
                state = .failed(String(localized: "Still working — check My packs later.", comment: "Shown when the foreground poll for a custom-pack order runs past its time budget; generation continues server-side and the pack appears in My packs when done"))
                return
            }

            let snapshot: OrderSnapshot
            do {
                snapshot = try await service.getOrder(id: orderId)
                consecutiveErrors = 0 // any success clears the transient-error run
            } catch {
                // Transient-error tolerance: a single network/timeout blip on
                // cellular must NOT mark a paid, still-generating order as failed
                // (that dead-ends the flow and invites a re-order / double charge).
                // Retry a few times; only a sustained run of errors is fatal.
                consecutiveErrors += 1
                if consecutiveErrors > Self.maxConsecutivePollErrors {
                    state = .failed(Self.message(for: error))
                    return
                }
                try? await Task.sleep(for: .seconds(pollIntervalSeconds))
                continue
            }

            if snapshot.isDelivered {
                state = .delivered(snapshot)
                return
            }
            if snapshot.isFailure {
                // A real terminal failure status — surface immediately, never retry.
                state = .failed(String(localized: "Pack generation failed. Please try again.", comment: "Shown when a custom-pack order ends in a failed/refunded state"))
                return
            }
            state = .polling(snapshot)

            do {
                try await Task.sleep(for: .seconds(pollIntervalSeconds))
            } catch {
                return // cancelled
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Something went wrong. Please try again.", comment: "Generic custom-pack order error fallback")
    }
}
