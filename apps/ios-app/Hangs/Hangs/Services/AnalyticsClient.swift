//
//  AnalyticsClient.swift
//  Hangs
//
//  #51: the product analytics seam. Callers hand over an event and move on —
//  tracking never blocks the UI and never surfaces an error. The live client
//  batches to `POST /api/v1/analytics/events`; previews, UI tests and unit
//  tests get the no-op (or `MockAnalyticsClient`).
//

protocol AnalyticsClient {
    /// `sessionId` ties a quiz event to the server's own quiz events.
    func track(_ event: AnalyticsEvent, sessionId: String?)
    /// Send whatever is queued now (the app is going to the background).
    func flush()
}

extension AnalyticsClient {
    func track(_ event: AnalyticsEvent) {
        track(event, sessionId: nil)
    }
}

struct NoopAnalyticsClient: AnalyticsClient {
    func track(_: AnalyticsEvent, sessionId _: String?) {}
    func flush() {}
}
