//
//  OrderPackViewModel.swift
//  Hangs
//
//  Drives the custom-pack order form + delivery poll (issue #95). Creates an
//  order via PackOrderService, then polls `getOrder` at 1 Hz until the order is
//  terminal (delivered / failed / refunded), publishing each step so the
//  progress view can render it. The poll task is cancelled on stop()/deinit.
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

    // MARK: Form fields

    @Published var prompt: String = ""
    @Published var language: String = "en"
    @Published var category: String = ""
    @Published var theme: String = ""

    @Published private(set) var state: OrderState = .editing

    private let service: PackOrderServiceProtocol
    private var pollTask: Task<Void, Never>?

    init(service: PackOrderServiceProtocol) {
        self.service = service
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

        let created: OrderCreatedResponse
        do {
            created = try await service.createOrder(
                prompt: trimmedPrompt,
                language: language,
                category: trimmedCategory.isEmpty ? nil : trimmedCategory,
                theme: trimmedTheme.isEmpty ? nil : trimmedTheme
            )
        } catch {
            state = .failed(Self.message(for: error))
            return
        }

        await poll(orderId: created.orderId)
    }

    private func poll(orderId: String) async {
        while !Task.isCancelled {
            let snapshot: OrderSnapshot
            do {
                snapshot = try await service.getOrder(id: orderId)
            } catch {
                state = .failed(Self.message(for: error))
                return
            }

            if snapshot.isDelivered {
                state = .delivered(snapshot)
                return
            }
            if snapshot.isFailure {
                state = .failed(String(localized: "Pack generation failed. Please try again.", comment: "Shown when a custom-pack order ends in a failed/refunded state"))
                return
            }
            state = .polling(snapshot)

            do {
                try await Task.sleep(for: .seconds(1))
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
