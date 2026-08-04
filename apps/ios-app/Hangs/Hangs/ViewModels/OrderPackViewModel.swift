//
//  OrderPackViewModel.swift
//  Hangs
//
//  Drives the custom-pack order flow (#95, redesigned in #138). One state
//  machine backs the whole modal: editing → confirming (payment summary) →
//  submitting → polling → delivered/failed. Once `submitting` is entered the
//  order is paid-for and irreversible, so NO public call can walk the state
//  back to the form or the summary for that order — the founder field test
//  (2026-08-04) landed back on the form after ordering and nearly re-paid.
//  The poll task is cancelled on stop()/deinit only; it deliberately survives
//  the sheet being dismissed, because delivery can complete while it is closed.
//

import Combine
import Foundation
import os

@MainActor
final class OrderPackViewModel: ObservableObject {
    /// Form + purchase + delivery lifecycle. `Equatable` so SwiftUI can diff
    /// transitions (mirrors StoreManager.PurchaseState).
    enum OrderState: Equatable {
        case editing
        /// Payment summary — the last screen with a way back to the form.
        case confirming
        case submitting
        case polling(OrderSnapshot)
        case delivered(OrderSnapshot)
        case failed(String)
    }

    /// Prompt ceiling. There is no floor beyond "not empty" (#138 B): the
    /// server enforces no minimum, and the old 10-char rule rejected perfectly
    /// good one-word topics ("Bratislava").
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

    /// Wire language of the ordered pack. Written only through
    /// `selectLanguage(_:)` so the view model can tell an explicit user choice
    /// from the value it preselects out of the global quiz language.
    @Published private(set) var language: String = Language.default.id

    @Published private(set) var state: OrderState = .editing

    private let service: PackOrderServiceProtocol
    private var pollTask: Task<Void, Never>?

    /// Set once the order exists server-side. A "Try again" after that point is a
    /// retry of THAT order (`POST /v1/orders/{id}/retry`), never a second paid
    /// create — the backend caps manual retries at 3.
    private(set) var orderId: String?

    /// True once the user has picked a language by hand for the current order;
    /// stops `prepareForPresentation` from stomping the choice on reopen.
    private var hasChosenLanguage = false

    /// The intent behind the order currently being submitted (or last failed).
    /// Kept alive across a retry of the SAME form content so `createOrder`
    /// reuses the same idempotency key rather than minting a new one on every
    /// call (issue #103 finding 6a) — cleared once the create succeeds, since
    /// a later submit with the same content is then a genuinely new order.
    private var pendingIntent: PackOrderIntent?

    init(service: PackOrderServiceProtocol) {
        self.service = service
    }

    deinit {
        pollTask?.cancel()
    }

    /// True when the trimmed prompt is non-empty and within the server ceiling.
    var isValid: Bool {
        (1...Self.maxPromptLength).contains(trimmedPromptCount)
    }

    /// Live character count of the trimmed prompt (for the counter UI).
    var trimmedPromptCount: Int {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    /// Swipe-to-dismiss is blocked only while the purchase call is in flight —
    /// dismissing then would leave the user unsure whether they paid. Every other
    /// state (including `.polling`) is dismissible: closing the sheet is not
    /// cancelling the order.
    var allowsInteractiveDismiss: Bool {
        state != .submitting
    }

    // MARK: Actions

    /// Sheet (re)opened. A terminal order is done with — start a fresh one. An
    /// in-flight one is shown exactly where it is, so reopening lands on
    /// "Preparing", never back on the form the user already paid from.
    func prepareForPresentation(defaultLanguage: String) {
        switch state {
        case .delivered, .failed:
            resetForNewOrder(defaultLanguage: defaultLanguage)
        case .editing:
            // Only preselect what the user hasn't already overridden.
            if !hasChosenLanguage {
                language = Self.supportedLanguage(defaultLanguage)
            }
        case .confirming, .submitting, .polling:
            break
        }
    }

    /// Explicit user language pick (form menu).
    func selectLanguage(_ code: String) {
        language = Self.supportedLanguage(code)
        hasChosenLanguage = true
    }

    /// Form → payment summary. Guarded on `.editing` so it can never re-enter
    /// the pre-purchase flow from a submitted order.
    func advanceToSummary() {
        guard state == .editing, isValid else { return }
        state = .confirming
    }

    /// Summary → form. The ONLY backwards transition in the machine, and it
    /// exists only before the purchase call goes out.
    func backToEdit() {
        guard state == .confirming else { return }
        state = .editing
    }

    /// Pay & create the order, then poll to completion. Only legal from the
    /// payment summary. Awaits the full lifecycle so a caller (or test) can
    /// inspect the terminal `state` afterwards; the running work is also held in
    /// `pollTask` so `stop()`/`deinit` can cancel it.
    func submit() async {
        guard state == .confirming, isValid else { return }
        state = .submitting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runOrder()
        }
        pollTask = task
        await task.value
    }

    /// "Try again" from the failed state. If the order was created server-side
    /// we re-enqueue THAT order (no second charge); if the create itself never
    /// landed we resubmit the same intent, whose idempotency key is unchanged.
    func retry() async {
        guard case .failed = state else { return }
        state = .submitting

        let existingOrderId = orderId
        let task = Task { [weak self] in
            guard let self else { return }
            if let existingOrderId {
                await self.retryExistingOrder(orderId: existingOrderId)
            } else {
                await self.runOrder()
            }
        }
        pollTask = task
        await task.value
    }

    /// Cancel any in-flight polling. NOT called on sheet dismissal — the user
    /// closing the "Preparing" sheet is not a cancellation, and the pack must
    /// keep arriving behind it.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Internal

    private func resetForNewOrder(defaultLanguage: String) {
        stop()
        orderId = nil
        pendingIntent = nil
        hasChosenLanguage = false
        language = Self.supportedLanguage(defaultLanguage)
        // The prompt text is deliberately kept — reordering a variation of the
        // last topic is the common case, and retyping it is pure friction.
        state = .editing
    }

    /// Maps a quiz-language code onto the order languages we support, falling
    /// back to English rather than sending the server an unknown code.
    private static func supportedLanguage(_ code: String) -> String {
        Language.forCode(code)?.id ?? Language.default.id
    }

    private func runOrder() async {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reuse the pending intent (and its idempotency key) when the form
        // content is unchanged from the last attempt — a retry after a create
        // that never landed. Any change to the fields is a genuinely new
        // intent, so it mints a fresh key rather than reusing a stale one.
        let intent: PackOrderIntent
        if let pending = pendingIntent,
           pending.prompt == trimmedPrompt,
           pending.language == language {
            intent = pending
        } else {
            // #138 dropped the category/theme inputs (meaningless even to the
            // founder); the wire fields stay, always nil, so the API contract
            // is untouched.
            intent = PackOrderIntent(
                prompt: trimmedPrompt,
                language: language,
                category: nil,
                theme: nil
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
        orderId = created.orderId

        await poll(orderId: created.orderId)
    }

    private func retryExistingOrder(orderId: String) async {
        do {
            _ = try await service.retryOrder(id: orderId)
        } catch {
            state = .failed(Self.message(for: error))
            return
        }
        await poll(orderId: orderId)
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
