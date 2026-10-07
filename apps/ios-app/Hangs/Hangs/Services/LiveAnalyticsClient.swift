//
//  LiveAnalyticsClient.swift
//  Hangs
//
//  #51: in-memory queue → batched, fire-and-forget POSTs through the
//  authorized `NetworkService` path. A batch goes out when `batchThreshold`
//  events are queued, `flushDelay` after the first queued event, or on
//  `flush()` (the app going to the background). A failed POST is tried once
//  more, then dropped: analytics never persist to disk and never retry beyond
//  that, so they cannot pile up behind a dead network.
//

import Clocks
import Foundation
import os

final class LiveAnalyticsClient: AnalyticsClient {
    /// Stays under the server's `MAX_BATCH` (50), so one flush is one request.
    static let batchThreshold = 20
    static let flushDelay: Duration = .seconds(10)
    static let maxAttempts = 2

    private let networkService: NetworkServiceProtocol
    private let clock: AnyClock<Duration>
    private var pending: [AnalyticsBatch.Event] = []
    private var flushTimer: Task<Void, Never>?

    init(networkService: NetworkServiceProtocol, clock: AnyClock<Duration> = .continuous) {
        self.networkService = networkService
        self.clock = clock
    }

    func track(_ event: AnalyticsEvent, sessionId: String?) {
        pending.append(AnalyticsBatch.Event(
            name: event.name,
            occurredAt: .now,
            sessionId: sessionId,
            properties: event.properties
        ))
        if pending.count >= Self.batchThreshold {
            flush()
        } else if flushTimer == nil {
            let clock = clock
            flushTimer = Task { [weak self] in
                try? await clock.sleep(for: Self.flushDelay)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        flushTimer?.cancel()
        flushTimer = nil
        guard !pending.isEmpty else { return }
        let batch = AnalyticsBatch(events: pending)
        pending.removeAll()
        let networkService = networkService
        Task {
            for _ in 0 ..< Self.maxAttempts {
                do {
                    try await networkService.postAnalyticsEvents(batch)
                    return
                } catch {
                    continue
                }
            }
            Logger.network.info("📊 Analytics batch dropped (\(batch.events.count, privacy: .public) events)")
        }
    }
}
