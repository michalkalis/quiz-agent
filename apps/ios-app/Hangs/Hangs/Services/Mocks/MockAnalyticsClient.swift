//
//  MockAnalyticsClient.swift
//  Hangs
//
//  #51: records every tracked event so tests assert what fired, in order.
//

#if DEBUG
    final class MockAnalyticsClient: AnalyticsClient {
        struct Tracked: Equatable {
            let event: AnalyticsEvent
            let sessionId: String?
        }

        private(set) var tracked: [Tracked] = []
        private(set) var flushCount = 0

        var events: [AnalyticsEvent] {
            tracked.map(\.event)
        }

        func events(named name: String) -> [AnalyticsEvent] {
            events.filter { $0.name == name }
        }

        func track(_ event: AnalyticsEvent, sessionId: String?) {
            tracked.append(Tracked(event: event, sessionId: sessionId))
        }

        func flush() {
            flushCount += 1
        }
    }
#endif
